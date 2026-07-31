package com.example.my_translate.asr

import android.content.res.AssetManager
import android.util.Log
import com.k2fsa.sherpa.onnx.*

/**
 * 单个 Sherpa-ONNX 流式识别器包装。
 *
 * 统一封装 transducer（bilingual zh-en）与 CTC（T-one 俄语）两种架构的差异，
 * 对外提供统一的 feed / partialText / finalizeSegment / reset / decodeBuffer 接口。
 *
 * 模型直接从 assets 加载（assetManager + asset 相对路径），无需拷贝到内部存储。
 *
 * @param assetManager 用于从 assets 读取模型（由 Context.assets 传入）
 * @param type         模型类型：bilingual（transducer）或 russian（CTC）
 * @param cfg          AsrConfig（取 numThreads / sampleRate）
 */
class SherpaRecognizer(
    private val assetManager: AssetManager,
    private val type: ModelType,
    private val cfg: AsrConfig,
) {
    enum class ModelType { BILINGUAL, RUSSIAN }

    private val tag = "SherpaRecognizer"

    private val recognizer: OnlineRecognizer
    private var stream: OnlineStream

    init {
        val config = buildConfig(cfg)
        recognizer = OnlineRecognizer(assetManager, config)
        stream = recognizer.createStream()
    }

    private fun buildConfig(cfg: AsrConfig): OnlineRecognizerConfig {
        val feat = FeatureConfig(sampleRate = cfg.sampleRate, featureDim = 80)

        val model: OnlineModelConfig = when (type) {
            ModelType.BILINGUAL -> {
                // streaming-zipformer-bilingual-zh-en-2023-02-20 (transducer)
                val transducer = OnlineTransducerModelConfig(
                    encoder = "models/zh_en/encoder-epoch-99-avg-1.int8.onnx",
                    decoder = "models/zh_en/decoder-epoch-99-avg-1.int8.onnx",
                    joiner = "models/zh_en/joiner-epoch-99-avg-1.int8.onnx",
                )
                OnlineModelConfig(
                    transducer = transducer,
                    tokens = "models/zh_en/tokens.txt",
                    numThreads = cfg.numThreads,
                    debug = false,
                )
            }
            ModelType.RUSSIAN -> {
                // streaming-t-one-russian-2025-09-08 (CTC, zipformer2)
                // 官方压缩包仅含 fp32 model.onnx（无 int8）
                val ctc = OnlineZipformer2CtcModelConfig(model = "models/ru/model.onnx")
                OnlineModelConfig(
                    zipformer2Ctc = ctc,
                    tokens = "models/ru/tokens.txt",
                    numThreads = cfg.numThreads,
                    debug = false,
                )
            }
        }

        // 端点检测（句末切分）委托给默认 EndpointConfig；
        // 真正的句子边界主要由 VAD 负责，识别器 endpoint 作兜底。
        // 注：v1.12.14 的 endpoint 规则已收进嵌套的 EndpointConfig，
        // 不再以 rule1MinTrailingSilence/rule2MinUtteranceLength 等独立命名参数暴露。
        // A.1.1：transducer（bilingual）支持 modified_beam_search，缓解重复吐字/截断；
        // CTC（俄语）只支持 greedy_search，保持默认以免初始化报错。
        val isTransducer = type == ModelType.BILINGUAL
        val decodingMethod = if (isTransducer) "modified_beam_search" else "greedy_search"
        return OnlineRecognizerConfig(
            featConfig = feat,
            modelConfig = model,
            decodingMethod = decodingMethod,
            // A.1.2：慢语速下 transducer 在长持续音上反复发射同一非 blank token（"三三三"），
            // beam width=4 抑制不足。加大到 8 让搜索更充分，更易收敛到"发一次+持续 blank"路径。
            // 仅影响 modified_beam_search；CTC(俄语) 走 greedy 忽略此字段，无副作用。
            // 注意：blank_penalty 方向恰相反（提高会加重 insertion/重复，仅对漏字 deletion 有效），故不用于本场景。
            // 官方 Kotlin 绑定字段名为顶层 `maxActivePaths`（对应 C-API max_active_paths），非 numActivePaths。
            maxActivePaths = if (isTransducer) 8 else 4,
            enableEndpoint = true,
        )
    }

    /** 喂入一帧 PCM（float 归一化 -1.0~1.0） */
    fun feed(samples: FloatArray) {
        stream.acceptWaveform(samples, cfg.sampleRate)
    }

    /** 解码当前缓冲 */
    fun decode() {
        while (recognizer.isReady(stream)) {
            recognizer.decode(stream)
        }
    }

    /** 当前 partial 文本（不 reset） */
    val partialText: String
        get() = recognizer.getResult(stream).text ?: ""

    /** 是否检测到端点（句末静音） */
    fun isEndpoint(): Boolean {
        return recognizer.isEndpoint(stream)
    }

    /** 取最终结果并重置流（用于句末提交） */
    fun finalizeSegment(): Result {
        val text = recognizer.getResult(stream).text ?: ""
        recognizer.reset(stream)
        return Result(text = text.trim())
    }

    /** 重置流（丢弃当前 partial） */
    fun reset() {
        recognizer.reset(stream)
    }

    /**
     * 对一段完整 PCM 做离线式重解码（模式 B 兜底用）。
     * 新建临时 stream，整段喂入，出结果后丢弃。
     */
    fun decodeBuffer(samples: FloatArray): Result {
        val tmpStream = recognizer.createStream()
        tmpStream.acceptWaveform(samples, cfg.sampleRate)
        while (recognizer.isReady(tmpStream)) {
            recognizer.decode(tmpStream)
        }
        val text = recognizer.getResult(tmpStream).text ?: ""
        return Result(text = text.trim())
    }

    /** 释放原生资源 */
    fun release() {
        // OnlineStream / OnlineRecognizer 由 GC 回收
    }

    /** 识别结果 */
    data class Result(val text: String)
}
