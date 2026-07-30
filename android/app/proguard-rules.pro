# android/app/proguard-rules.pro
# sherpa-onnx / onnxruntime 保留规则
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class ai.onnxruntime.** { *; }
