# 构建与安装（Android）

本仓库只含 Flutter **源码**（`lib/`），缺少 `android/` 等平台工程文件。
按下面步骤在你自己的电脑上生成平台工程并编译成 APK 即可。

## 1. 前置环境
- 安装 **Flutter SDK 3.7.x（Dart 2.19）**：https://docs.flutter.dev/get-started/install
  > ⚠️ 必须用 3.7.x。本工程依赖 `vosk_flutter 0.3.48`，它只支持 Dart `<3.0.0`；
  > 用 3.10+（Dart 3）会导致 `flutter pub get` 直接失败。CI 里已锁定 `3.7.12`。
- 安装 **Android SDK**（用 Android Studio 的 SDK Manager），并配置 `ANDROID_HOME` / `ANDROID_SDK_ROOT`
- 接受许可：`flutter doctor --android-licenses`
- 手机开启「开发者选项 → USB 调试」，用 USB 连接电脑

验证环境：
```bash
flutter doctor
```

## 2. 生成平台工程（不会覆盖你的 lib/ 与 pubspec.yaml）
在项目根目录执行：
```bash
flutter create .
```
若提示已存在，可改用：
```bash
flutter create --platforms=android .
```

## 3. 添加权限
打开 `android/app/src/main/AndroidManifest.xml`，在 `<manifest>` 下、`<application>` 之前加入：
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```
并在 `<application>` 之前加入（启用 Google 在线识别）：
```xml
<queries>
  <intent>
    <action android:name="android.speech.RecognitionService" />
  </intent>
</queries>
```
同时确保最小 SDK ≥ 21：在 `android/app/build.gradle` 的 `defaultConfig` 里设置
```gradle
minSdk = 21
```

## 4. 安装依赖并构建
```bash
flutter pub get
flutter build apk --debug
```
> 自用调试版用 `--debug` 即可；若要发布版去掉 `--debug`（即 `flutter build apk`）。

## 5. 安装到手机
```bash
flutter install
```
或把 `build/app/outputs/flutter-apk/app-debug.apk` 拷到手机手动安装。

## 6. 首次运行说明
- **Vosk 模式（默认）**：首次会联网下载所选外语 + 中文两个小模型（英文约 40MB / 俄语约 45MB / 中文约 42MB），存到应用私有目录，之后可完全离线使用，并自动判别外语与中文。
- **Google 模式**：需联网且设备已安装 Google 语音服务；在 App 内「设置」可切换，并选择识别外语（英文 / 俄语）。注意 Google 为单语种，只监听所选外语，「听中文 → 同传」方向不会触发。
- 听外语（英文 / 俄语）→ 屏幕生成大字号、可滚动的中文笔记字幕；听中文 → 自动朗读对应外语（同声传译）。
- **翻译后端（国内大模型）**：在 App「设置」里选择供应商（智谱 GLM / 通义千问 / 豆包），粘贴对应 API Key 即可。三家都用中国手机号注册、有免费额度，**无需外币信用卡**。默认模型：GLM `glm-4-flash` / 千问 `qwen-turbo` / 豆包 `doubao-seed-1.6-250615`。

## 7. 云端构建（推荐：无需本机下载 SDK）

如果你本地下不动 Flutter / Android SDK，用云端 CI 构建最省事——**本机完全不装 SDK**，
只把代码推到仓库，CI 服务器（网络好）自动编译，你最后下载一个 ~40MB 的 APK 即可。

工程里已备好两份配置，二选一：

### 方案 A：GitHub Actions（免费，需 GitHub 账号）
工程已被初始化为本地 git 仓库（分支 `main`，首版已 commit）。你只需：

1. 在 GitHub 网页 **新建一个空仓库**（命名随意，如 `my-translate`；**不要**勾选初始化 README / .gitignore / License，保持空仓库，否则首次 push 会冲突）。
2. 复制该仓库的 HTTPS 地址（形如 `https://github.com/你的用户名/my-translate.git`），在本机 `E:\MY_TANSLATE` 目录下执行：
   ```bash
   git remote add origin https://github.com/你的用户名/my-translate.git
   git branch -M main
   git push -u origin main
   ```
   > 首次 push 会弹出 GitHub 登录（浏览器或 token）。若用 token，需在 GitHub → Settings → Developer settings 生成 **fine-grained PAT**，勾选该仓库的 `contents: write` 权限。
3. push 完成后，GitHub 的 **Actions** 标签页会自动识别 `.github/workflows/build-apk.yml` 并开始构建；
   也可进 Actions → 选 `Build Debug APK` → `Run workflow` 手动触发。
4. 跑完后到 **Actions → 本次运行 → Artifacts** 下载 `my-translate-debug` 里的 `app-debug.apk`，拷到手机安装。

### 方案 B：CodeMagic（Flutter 原生，免费 500 分钟/月）
1. 打开 https://codemagic.io ，用 GitHub / GitLab / Gitee 授权登录。
2. 添加本仓库，CodeMagic 会读取根目录的 `codemagic.yaml`。
3. 点 **Start new build**，结束后在 Artifacts 下载 `app-debug.apk`。

> 两份配置都会自动执行 `flutter create --platforms=android .` 生成平台工程，
> 并自动补好 `RECORD_AUDIO` / `INTERNET` 权限与 `minSdk = 21`，不用你手动改。

## 8. 备注
- 翻译后端用 **国内大模型**（OpenAI 兼容 Chat 接口：智谱 GLM / 通义千问 / 豆包），需在「设置」选择供应商并填入对应 API Key，均可中国手机号注册、**无需外币信用卡**。Key 存于本机 `shared_preferences`，不上传。
- 若开启代码混淆（minify/shrink），在 `android/app/proguard-rules.pro` 加入 Vosk 的 JNA 保留规则：
```
-keep class com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }
```
