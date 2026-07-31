package com.example.my_translate.asr

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * 生命周期总控：权限校验、HandlerThread 管理、start/stop 幂等、异常重启。
 *
 * 线程模型：
 * - audio 线程（AudioCapture 内部）→ 帧入队 inference HandlerThread
 * - inference HandlerThread（唯一推理线程）：VAD + ASR 串行
 * - 事件经 mainHandler 抛回主线程再进 EventChannel
 */
class AudioSessionManager(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val tag = "AudioSessionManager"

    private var cfg: AsrConfig = AsrConfig()
    private var recognizerManager: RecognizerManager? = null
    private var vadProcessor: VadProcessor? = null
    private var audioCapture: AudioCapture? = null

    private var inferenceThread: HandlerThread? = null
    private var inferenceHandler: Handler? = null

    @Volatile private var running = false

    /** 是否有麦克风权限（只做兜底校验，申请在 Dart 侧 permission_handler） */
    private fun hasMicPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * 启动会话（幂等：已在跑则先 stop）。
     * @param mode "zhEn" | "zhRu"
     */
    fun start(mode: String) {
        if (running) {
            Log.w(tag, "已在运行，先 stop 再 start")
            stop()
        }

        if (!hasMicPermission()) {
            emit(mapOf("type" to "error", "text" to "需要麦克风权限"))
            return
        }

        // 创建 inference 线程
        inferenceThread = HandlerThread("inference").apply { start() }
        inferenceHandler = Handler(inferenceThread!!.looper)

        running = true

        // 在 inference 线程加载模型
        inferenceHandler!!.post {
            try {
                emit(mapOf("type" to "status", "text" to "正在加载模型…"))

                recognizerManager = RecognizerManager(context, cfg, ::handleEvent)
                recognizerManager?.load(mode)

                // VAD（Phase A：负责句子边界切分）
                vadProcessor = VadProcessor(context.assets, cfg) {
                    // VAD 判定一句话结束 → 通知 RecognizerManager finalize
                    recognizerManager?.onVadSegmentEnd()
                }

                emit(mapOf("type" to "ready"))

                // 启动采集
                audioCapture = AudioCapture(cfg) { samples ->
                    // audio 线程 → inference 线程
                    inferenceHandler?.post {
                        if (!running) return@post
                        // 1. VAD（如果 speech segment 就绪，会回调 onVadSegmentEnd）
                        vadProcessor?.process(samples)
                        // 2. ASR（feed + decode + endpoint 检测 + partial/final）
                        recognizerManager?.onFrame(samples)
                    }
                }
                audioCapture?.start()

                emit(mapOf("type" to "status", "text" to "监听中"))

            } catch (e: Exception) {
                Log.e(tag, "启动失败", e)
                emit(mapOf("type" to "error", "text" to "启动失败：${e.message}"))
                stopInternal()
            }
        }
    }

    /** 停止会话（幂等） */
    fun stop() {
        if (!running) return
        stopInternal()
    }

    private fun stopInternal() {
        running = false

        // 在 inference 线程安全释放
        inferenceHandler?.post {
            // 1. 停采集
            audioCapture?.stop()
            audioCapture = null

            // 2. 冲刷尾部
            vadProcessor?.flush()
            recognizerManager?.flushLast()

            // 3. 释放
            vadProcessor?.release()
            recognizerManager?.release()
            vadProcessor = null
            recognizerManager = null

            emit(mapOf("type" to "status", "text" to "已停止"))
        }

        // 4. 关闭 inference 线程
        inferenceThread?.quitSafely()
        try {
            inferenceThread?.join(1000)
        } catch (_: InterruptedException) {}
        inferenceThread = null
        inferenceHandler = null
    }

    /** 手动设置活跃语言（模式 B 手动 Chip） */
    fun setActiveLang(lang: String) {
        inferenceHandler?.post {
            recognizerManager?.setActiveLang(lang)
        }
    }

    /** 暂停麦克风采集投喂（TTS 播放期间，防回声自触发） */
    fun pauseCapture() {
        audioCapture?.pause()
    }

    /** 恢复麦克风采集投喂（TTS 结束 + 冷却期后） */
    fun resumeCapture() {
        audioCapture?.resume()
    }

    /** 热更新配置 */
    fun setConfig(newCfg: AsrConfig) {
        cfg = newCfg
    }

    /** 推理线程内产生的事件 → 经 emit 回调（由 AsrPlugin 切主线程） */
    private fun handleEvent(event: Map<String, Any?>) {
        emit(event)
    }
}
