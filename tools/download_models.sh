#!/usr/bin/env bash
# 下载 Vosk 离线语音模型到 assets/models/，随后随 APK 打包，
# 手机端通过 ModelLoader.loadFromAssets 从安装包内离线加载，无需联网。
#
# 用法（在 Git Bash / WSL / macOS 终端中执行）：
#   cd <项目根目录>
#   bash tools/download_models.sh
#
# 若电脑也访问不到 alphacephei.com，先开代理再跑，例如：
#   export https_proxy=http://127.0.0.1:7890
#   export http_proxy=http://127.0.0.1:7890
set -e

OUT="assets/models"
mkdir -p "$OUT"

# 文件名必须与 lib/services/speech/vosk_engine.dart 中常量一致
declare -A urls=(
  ["vosk-model-small-en-us-0.15.zip"]="https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
  ["vosk-model-small-cn-0.22.zip"]="https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip"
  ["vosk-model-small-ru-0.22.zip"]="https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip"
)

for f in "${!urls[@]}"; do
  if [ -f "$OUT/$f" ]; then
    echo "已存在，跳过: $f"
    continue
  fi
  echo "下载中: $f ..."
  curl -fL -o "$OUT/$f" "${urls[$f]}"
done

echo "完成。模型位于 $OUT/，请执行："
echo "  git add assets/models && git commit -m 'chore: 捆绑 Vosk 离线模型' && git push"
echo "推送后 GitHub Actions 会把模型编进 APK，手机端即可离线加载。"
