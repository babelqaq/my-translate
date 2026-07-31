package com.example.my_translate.asr

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Channel 边界：Kotlin ASR 层与 Flutter 的唯一接触点。
 *
 * - MethodChannel "asr/control"（下行）：start / stop / setActiveLang / setConfig
 * - EventChannel "asr/events"（上行）：ready / status / partial / final / error（JSON）
 *
 * 所有 emit 必须切主线程（Flutter 平台通道要求）。
 */
class AsrPlugin private constructor(
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val tag = "AsrPlugin"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private val sessionManager = AudioSessionManager(context, ::emit)

    companion object {
        private const val METHOD_CHANNEL = "asr/control"
        private const val EVENT_CHANNEL = "asr/events"

        /**
         * Flutter embedding v2 注册入口。
         * 在 MainActivity.configureFlutterEngine 中调用。
         */
        @JvmStatic
        fun register(context: Context, engine: FlutterEngine) {
            val plugin = AsrPlugin(context)
            val messenger = engine.dartExecutor.binaryMessenger
            MethodChannel(messenger, METHOD_CHANNEL)
                .setMethodCallHandler(plugin)
            EventChannel(messenger, EVENT_CHANNEL)
                .setStreamHandler(plugin)
        }
    }

    // ---------- MethodChannel（下行） ----------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val mode = call.argument<String>("mode") ?: "zhEn"
                    sessionManager.start(mode)
                    result.success(null)
                }
                "stop" -> {
                    sessionManager.stop()
                    result.success(null)
                }
                "setActiveLang" -> {
                    val lang = call.argument<String>("lang") ?: "auto"
                    sessionManager.setActiveLang(lang)
                    result.success(null)
                }
                "setConfig" -> {
                    val json = call.argument<String>("config")
                    if (json != null) {
                        val cfg = parseConfig(json)
                        sessionManager.setConfig(cfg)
                    }
                    result.success(null)
                }
                "pauseCapture" -> {
                    sessionManager.pauseCapture()
                    result.success(null)
                }
                "resumeCapture" -> {
                    sessionManager.resumeCapture()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(tag, "Method call error: ${call.method}", e)
            result.error("ASR_ERROR", e.message, null)
        }
    }

    // ---------- EventChannel（上行） ----------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        // 只断 sink，不停会话（防热重载误停）
        eventSink = null
    }

    // ---------- 事件发射（切主线程） ----------

    private fun emit(event: Map<String, Any?>) {
        val json = JSONObject(event).toString()
        mainHandler.post {
            eventSink?.success(json)
        }
    }

    // ---------- 配置解析 ----------

    private fun parseConfig(json: String): AsrConfig {
        val obj = JSONObject(json)
        val map = mutableMapOf<String, Any?>()
        for (key in obj.keys()) {
            map[key] = obj.get(key)
        }
        return AsrConfig.fromMap(map)
    }
}
