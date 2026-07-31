package com.example.my_translate.asr

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlin.math.max

/**
 * 麦克风采集：AudioRecord → PCM16 mono 16kHz → FloatArray（/32768 归一化）。
 *
 * 独立 audio 线程 read 循环，每 frameMs（默认 100ms = 1600 samples）一帧，
 * 投递到 [onFrame] 回调（在 audio 线程执行，调用方需自行线程切换）。
 *
 * @param cfg     AsrConfig（取 sampleRate / frameMs）
 * @param onFrame 每帧回调（FloatArray，归一化 -1.0~1.0）
 */
class AudioCapture(
    private val cfg: AsrConfig,
    private val onFrame: (FloatArray) -> Unit,
) {
    private val tag = "AudioCapture"

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false

    fun start() {
        if (capturing) return

        val sampleRate = cfg.sampleRate
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT

        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val frameBytes = cfg.frameSamples * 2  // PCM16 = 2 bytes/sample
        val bufferSize = max(minBuf, frameBytes * 4)

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,  // 语音识别优化源
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize,
        )

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(tag, "AudioRecord 初始化失败")
            throw IllegalStateException("AudioRecord 初始化失败")
        }

        capturing = true
        audioRecord?.startRecording()
        captureThread = Thread({ captureLoop() }, "audio-capture").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun captureLoop() {
        val frameSamples = cfg.frameSamples
        val shortBuffer = ShortArray(frameSamples)
        val floatBuffer = FloatArray(frameSamples)

        while (capturing) {
            val read = audioRecord?.read(shortBuffer, 0, frameSamples) ?: -1
            if (read <= 0) {
                if (read == AudioRecord.ERROR_INVALID_OPERATION ||
                    read == AudioRecord.ERROR_BAD_VALUE
                ) {
                    Log.e(tag, "AudioRecord read 失败: $read")
                }
                continue
            }

            // PCM16 → float 归一化（/32768f）
            for (i in 0 until read) {
                floatBuffer[i] = shortBuffer[i] / 32768f
            }

            // 只投递有效部分
            val frame = if (read == frameSamples) floatBuffer else floatBuffer.copyOf(read)
            onFrame(frame)
        }
    }

    fun stop() {
        capturing = false
        try {
            captureThread?.join(500)
        } catch (_: InterruptedException) {}
        captureThread = null
        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        audioRecord?.release()
        audioRecord = null
    }
}
