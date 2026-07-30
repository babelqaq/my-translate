package com.example.my_translate

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.my_translate.asr.AsrPlugin

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 Sherpa-ONNX ASR 插件（MethodChannel + EventChannel）
        AsrPlugin.register(this, flutterEngine)
    }
}
