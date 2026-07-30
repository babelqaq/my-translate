package com.example.my_translate.asr

/**
 * ASR 参数集中地（全部可由 Dart setConfig 热更）。
 * 见《项目总体规划.md》附录 13.3 参数表。
 */
data class AsrConfig(
    // ---------- VAD ----------
    var vadThreshold: Float = 0.5f,
    var minSilenceMs: Int = 800,
    var minSpeechMs: Int = 250,

    // ---------- 采集 ----------
    var frameMs: Int = 100,               // 每帧时长（100ms = 1600 samples @ 16kHz）
    val sampleRate: Int = 16000,

    // ---------- 模式 B 兜底 ----------
    var segmentBufferMaxSec: Int = 15,    // 兜底重解码环形缓冲上限

    // ---------- 字符集判定（Dart route 与 Kotlin charMatch 同值） ----------
    var charDominance: Float = 0.6f,      // 字符集"主导"判定比例

    // ---------- ASR ----------
    var numThreads: Int = 1,              // 推理线程数（int8 单线程足够）
) {
    /** 每帧采样数 = sampleRate * frameMs / 1000 */
    val frameSamples: Int get() = sampleRate * frameMs / 1000

    companion object {
        /** 从 Dart 传来的 JSON Map 构造（部分更新） */
        fun fromMap(map: Map<String, Any?>, defaults: AsrConfig = AsrConfig()): AsrConfig {
            return defaults.copy(
                vadThreshold = (map["vadThreshold"] as? Number)?.toFloat() ?: defaults.vadThreshold,
                minSilenceMs = (map["minSilenceMs"] as? Number)?.toInt() ?: defaults.minSilenceMs,
                minSpeechMs = (map["minSpeechMs"] as? Number)?.toInt() ?: defaults.minSpeechMs,
                frameMs = (map["frameMs"] as? Number)?.toInt() ?: defaults.frameMs,
                segmentBufferMaxSec = (map["segmentBufferMaxSec"] as? Number)?.toInt() ?: defaults.segmentBufferMaxSec,
                charDominance = (map["charDominance"] as? Number)?.toFloat() ?: defaults.charDominance,
                numThreads = (map["numThreads"] as? Number)?.toInt() ?: defaults.numThreads,
            )
        }
    }
}
