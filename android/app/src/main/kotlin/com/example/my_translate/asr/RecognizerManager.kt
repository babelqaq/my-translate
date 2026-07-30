package com.example.my_translate.asr

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * 识别器持有与 sticky 调度。
 *
 * - 模式 A（zhEn）：bilingual 单识别器，无切换问题。
 * - 模式 B（zhRu）：{bilingual(作 zh), russian} 双加载单活跃。
 *   推理只喂 active 识别器；final 时做字符集校验，不匹配才重解码（Phase D 启用）。
 *
 * @param context  Activity/Application context（用于 AssetManager）
 * @param cfg      AsrConfig
 * @param emit     事件回调（主线程调用由 AudioSessionManager 保证）
 */
class RecognizerManager(
    private val context: Context,
    private val cfg: AsrConfig,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val tag = "RecognizerManager"

    private var bilingual: SherpaRecognizer? = null
    private var russian: SherpaRecognizer? = null

    /** 当前模式 */
    private var mode: String = "zhEn"

    /** 当前活跃语言（模式 A 恒 "auto"；模式 B "zh"|"ru"，默认 "zh"） */
    private var activeLang: String = "auto"

    /** 是否已加载 */
    private var loaded = false

    // ---------- 模型加载 ----------

    /**
     * 按模式加载模型。在 inference 线程调用。
     * 从 assets 拷贝到内部存储后创建识别器。
     */
    fun load(mode: String) {
        if (loaded) release()
        this.mode = mode
        this.activeLang = if (mode == "zhRu") "zh" else "auto"

        val zhEnDir = copyAssetDir("models/zh_en", "zh_en")
        bilingual = SherpaRecognizer(zhEnDir, SherpaRecognizer.ModelType.BILINGUAL, cfg)

        if (mode == "zhRu") {
            val ruDir = copyAssetDir("models/ru", "ru")
            russian = SherpaRecognizer(ruDir, SherpaRecognizer.ModelType.RUSSIAN, cfg)
        }

        loaded = true
    }

    /** 从 assets 拷贝模型目录到内部存储，返回目标绝对路径 */
    private fun copyAssetDir(assetPath: String, dirName: String): String {
        val destDir = File(context.filesDir, "models/$dirName")
        if (!destDir.exists()) destDir.mkdirs()

        val files = context.assets.list(assetPath) ?: emptyArray()
        for (f in files) {
            val destFile = File(destDir, f)
            if (destFile.exists() && destFile.length() > 0) continue
            context.assets.open("$assetPath/$f").use { input ->
                FileOutputStream(destFile).use { output -> input.copyTo(output) }
            }
            Log.d(tag, "Copied $f → ${destFile.absolutePath} (${destFile.length()} bytes)")
        }
        return destDir.absolutePath
    }

    // ---------- 帧处理 ----------

    /** 喂帧给当前活跃识别器（仅一个推理在跑） */
    fun onFrame(samples: FloatArray) {
        val rec = activeRecognizer() ?: return
        rec.feed(samples)
        rec.decode()

        // 检查 endpoint（ASR 自带的句末静音检测）
        if (rec.isEndpoint()) {
            val result = rec.finalizeSegment()
            if (result.text.isNotEmpty()) {
                onSegmentEnd(result.text)
            }
        } else {
            // partial 更新
            val partial = rec.partialText
            if (partial.isNotEmpty()) {
                emit(mapOf("type" to "partial", "text" to partial))
            }
        }
    }

    /** VAD 判定句子结束时的回调（与 ASR endpoint 互补） */
    fun onVadSegmentEnd() {
        val rec = activeRecognizer() ?: return
        val result = rec.finalizeSegment()
        if (result.text.isNotEmpty()) {
            onSegmentEnd(result.text)
        }
    }

    /**
     * 句子结束处理：取 final 文本，做字符集校验。
     * 模式 A：直接上抛。
     * 模式 B：charMatch 失败 → 重解码（Phase D 才启用，Phase A 直接上抛）。
     */
    private fun onSegmentEnd(text: String) {
        if (mode == "zhEn") {
            // 模式 A：bilingual 单模型，直接上抛
            emit(mapOf("type" to "final", "text" to text))
            return
        }

        // 模式 B：字符集校验
        val matched = charMatch(text, activeLang)
        if (matched) {
            emit(mapOf("type" to "final", "text" to text))
        } else {
            // Phase A：直接上抛，靠手动 Chip
            // Phase D：用另一识别器对 SegmentBuffer 重解码，择优上抛
            Log.d(tag, "charMatch 失败 (activeLang=$activeLang, text='$text')，Phase A 直接上抛")
            emit(mapOf("type" to "final", "text" to text))
        }
    }

    // ---------- 手动语种切换 ----------

    /** 手动 Chip 设置活跃语言 */
    fun setActiveLang(lang: String) {
        if (mode == "zhEn") {
            // 模式 A：单识别器，不需要切换 Kotlin 侧
            // manualLang 只作用于 Dart route
            return
        }
        activeLang = if (lang == "auto") "zh" else lang  // auto 时默认 zh
        // 重置两识别器的流
        bilingual?.reset()
        russian?.reset()
        Log.d(tag, "setActiveLang: $activeLang")
    }

    // ---------- 生命周期 ----------

    /** 冲刷尾部（stop 时调用） */
    fun flushLast() {
        val rec = activeRecognizer() ?: return
        val result = rec.finalizeSegment()
        if (result.text.isNotEmpty()) {
            onSegmentEnd(result.text)
        }
    }

    fun release() {
        bilingual?.release()
        russian?.release()
        bilingual = null
        russian = null
        loaded = false
    }

    // ---------- 内部工具 ----------

    private fun activeRecognizer(): SherpaRecognizer? {
        if (mode == "zhEn") return bilingual
        return if (activeLang == "ru") russian else bilingual
    }

    /**
     * 字符集校验：text 的主导字符集是否与 lang 匹配。
     * zh → CJK 主导；ru → 西里尔主导；en → 拉丁主导。
     */
    private fun charMatch(text: String, lang: String): Boolean {
        if (text.isBlank()) return true
        var cjk = 0; var cyrillic = 0; var latin = 0; var other = 0
        for (ch in text) {
            when {
                ch.code in 0x4E00..0x9FFF -> cjk++
                ch.code in 0x0400..0x04FF -> cyrillic++
                ch in 'A'..'Z' || ch in 'a'..'z' -> latin++
                ch.isLetter() -> other++
            }
        }
        val total = cjk + cyrillic + latin + other
        if (total == 0) return true

        return when (lang) {
            "zh" -> cjk.toFloat() / total >= cfg.charDominance
            "ru" -> cyrillic.toFloat() / total >= cfg.charDominance
            "en" -> latin.toFloat() / total >= cfg.charDominance
            else -> true
        }
    }
}
