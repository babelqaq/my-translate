package com.example.my_translate.asr

import android.util.Log
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadConfig

/**
 * Silero VAD 包装：切句与门控。
 *
 * sherpa-onnx 的 Vad 类以「完整语音段」为单位输出（内部已做 start/end 检测）。
 * 本类在每帧 feed 后检查是否有新段输出，有则回调 [onSegmentEnd]。
 *
 * Phase A：VAD 与 ASR endpoint 互补——两者任一触发都 finalize ASR。
 * Phase D：启用 VAD 门控（静音期不喂 ASR，省电）。
 *
 * @param cfg       AsrConfig（取 vadThreshold / minSilenceMs / minSpeechMs / sampleRate）
 * @param onSegmentEnd  VAD 判定一句话结束时回调
 */
class VadProcessor(
    cfg: AsrConfig,
    private val onSegmentEnd: () -> Unit,
) {
    private val tag = "VadProcessor"
    private val vad: Vad

    init {
        val sileroConfig = SileroVadModelConfig(
            model = "models/vad/silero_vad.onnx",  // asset 相对路径（由 AssetManager 解析）
            threshold = cfg.vadThreshold,
            minSilenceDuration = cfg.minSilenceMs.toFloat() / 1000f,
            minSpeechDuration = cfg.minSpeechMs.toFloat() / 1000f,
        )
        val config = VadConfig(
            sampleRate = cfg.sampleRate,
            sileroVadModelConfig = sileroConfig,
        )
        vad = Vad(config = config)
    }

    /**
     * 喂入一帧 PCM。
     * 若 VAD 输出了完整的语音段（说话结束），回调 onSegmentEnd。
     */
    fun process(samples: FloatArray) {
        try {
            vad.accept(samples)
            while (!vad.isEmpty()) {
                val segment = vad.front()
                vad.pop()
                // 完整语音段就绪 = 一句话结束
                onSegmentEnd()
            }
        } catch (e: Exception) {
            Log.e(tag, "VAD process error", e)
        }
    }

    /** 强制冲刷当前语音段（stop 时调用） */
    fun flush() {
        try {
            vad.flush()
            while (!vad.isEmpty()) {
                vad.pop()
                onSegmentEnd()
            }
        } catch (e: Exception) {
            Log.e(tag, "VAD flush error", e)
        }
    }

    fun release() {
        // Vad 由 GC 回收
    }
}
