package com.example.my_translate.asr

import android.util.Log
import com.k2fsa.sherpa.onnx.*
import java.io.File

/**
 * 单个 Sherpa-ONNX 流式识别器包装。
 *
 * 统一封装 transducer（bilingual zh-en）与 CTC（T-one 俄语）两种架构的差异，
 * 对外提供统一的 feed / partialText / finalizeSegment / reset / decodeBuffer 接口。
 *
 * @param modelDir  模型目录的绝对路径（已从 assets 拷贝到内部存储）
 * @param type      模型类型：bilingual（transducer）或 russian（CTC）
 * @param cfg       AsrConfig（取 numThreads / sampleRate）
 */
class SherpaRecognizer(
    private val modelDir: String,
    private val type: ModelType,
    cfg: AsrConfig,
) {
    enum class ModelType { BILINGUAL, RUSSIAN }

    private val tag = "SherpaRecognizer"

    private val recognizer: OnlineRecognizer
    private var stream: OnlineStream

    init {
        val config = buildConfig(cfg)
        recognizer = OnlineRecognizer(config = config)
        stream = recognizer.createStream()
    }

    private fun buildConfig(cfg: AsrConfig): OnlineRecognizerConfig {
        val feat = FeatureConfig(sampleRate = cfg.sampleRate.toFloat())

        when (type) {
            ModelType.BILINGUAL -> {
                // streaming-zipformer-bilingual-zh-en-2023-02-20 (transducer)
                val transducer = OnlineTransducerModelConfig(
                    encoder = "$modelDir/encoder-epoch-99-avg-1.int8.onnx",
                    decoder = "$modelDir/decoder-epoch-99-avg-1.int8.onnx",
                    joiner = "$modelDir/joiner-epoch-99-avg-1.int8.onnx",
                )
                val model = OnlineModelConfig(
                    transducer = transducer,
                    tokens = "$modelDir/tokens.txt",
                    numThreads = cfg.numThreads,
                    debug = false,
                )
                return OnlineRecognizerConfig(
                    featConfig = feat,
                    modelConfig = model,
                    enableEndpoint = true,
                    rule1MinTrailingSilence = 0.8f,   // VAD minSilence 对齐
                    rule2MinUtteranceLength = 20.0f,   // 超长句自动截断
                )
            }
            ModelType.RUSSIAN -> {
                // streaming-t-one-russian-2025-09-08 (CTC)
                // 文件名以实际下载为准；常见为 model.int8.onnx
                val ctcModelFile = File(modelDir).listFiles()
                    ?.firstOrNull { it.name.endsWith(".onnx") }?.absolutePath
                    ?: "$modelDir/model.int8.onnx"

                val ctc = OnlineCtcModelConfig(model = ctcModelFile)
                val model = OnlineModelConfig(
                    ctc = ctc,
                    tokens = "$modelDir/tokens.txt",
                    numThreads = cfg.numThreads,
                    debug = false,
                )
                return OnlineRecognizerConfig(
                    featConfig = feat,
                    modelConfig = model,
                    enableEndpoint = true,
                    rule1MinTrailingSilence = 0.8f,
                    rule2MinUtteranceLength = 20.0f,
                )
            }
        }
    }

    /** 喂入一帧 PCM（float 归一化 -1.0~1.0） */
    fun feed(samples: FloatArray) {
        stream.acceptWaveform(samples)
    }

    /** 解码当前缓冲，返回是否有新结果 */
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
        tmpStream.acceptWaveform(samples)
        while (recognizer.isReady(tmpStream)) {
            recognizer.decode(tmpStream)
        }
        val text = recognizer.getResult(tmpStream).text ?: ""
        return Result(text = text.trim())
    }

    /** 释放原生资源 */
    fun release() {
        // OnlineStream / OnlineRecognizer 由 GC 回收，显式 release 按 AAR 实际 API 调整
    }

    /** 识别结果 */
    data class Result(val text: String)
}
