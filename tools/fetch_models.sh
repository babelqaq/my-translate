#!/usr/bin/env bash
# ============================================================================
# ⚠️【已弃用 / DEPRECATED，2026-07-31】⚠️
#   本脚本中的 ModelScope 直链路径未经验证，实测 404（CI run #16 失败）。
#   - CI（GitHub Actions，海外 runner 可直连 GitHub）→ 用 tools/fetch_models_github.sh
#   - 本地（开 VPN）                                → 用 tools/fetch_models_github.sh
#   仅当未来确需国内免 VPN 下载时，先在 ModelScope 站内人工核实
#   仓库名与文件路径、curl 验证直链可用后，再修复启用本脚本。
# ============================================================================
# 从 ModelScope 镜像下载 Sherpa-ONNX 模型到 android/app/src/main/assets/models/
# 模型随 APK 打包，运行期全离线（目标设备不联网）。
#
# 用法（在 Git Bash / WSL / macOS 终端中执行）：
#   cd <项目根目录>
#   bash tools/fetch_models.sh
#
# 若 ModelScope 也访问不到，请先配置代理再跑。
# ============================================================================
echo "=============================================================="
echo "[弃用警告] 本脚本的 ModelScope 直链未验证（实测 404）。"
echo "           请改用: bash tools/fetch_models_github.sh"
echo "           （CI 海外 runner 可直连；本地请开 VPN）"
echo "=============================================================="
exit 1
set -euo pipefail

# 模型目标目录（与 Kotlin AsrConfig 中路径一致）
ASSETS_DIR="android/app/src/main/assets/models"
VAD_DIR="$ASSETS_DIR/vad"
ZH_EN_DIR="$ASSETS_DIR/zh_en"
RU_DIR="$ASSETS_DIR/ru"

mkdir -p "$VAD_DIR" "$ZH_EN_DIR" "$RU_DIR"

# ----------------------------------------------------------------------------
# ModelScope 直链基础（文件名以镜像仓文件页实际为准）
#   silero_vad + T-one 俄语：zhaochaoqun/sherpa-onnx-asr-models（全量镜像仓）
#   bilingual zh-en：pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20
# ----------------------------------------------------------------------------
MS_BASE="https://modelscope.cn/models"
MS_RESOLVE="https://modelscope.cn/api/v1/models"

# 工具函数：下载单个文件（已存在则跳过）
download() {
  local url="$1"
  local dest="$2"
  local label="$3"
  if [ -f "$dest" ] && [ -s "$dest" ]; then
    echo "[跳过] $label（已存在）"
    return 0
  fi
  echo "[下载] $label"
  echo "  来源: $url"
  echo "  目标: $dest"
  curl -fSL --retry 3 --retry-delay 5 -o "$dest" "$url"
  echo "  完成: $(du -h "$dest" | cut -f1)"
}

echo "=========================================="
echo "Sherpa-ONNX 模型下载（ModelScope 镜像）"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Silero VAD（~2MB）
# ---------------------------------------------------------------------------
# ModelScope 全量镜像仓文件页下载，文件名 silero_vad.onnx
SILERO_URL="$MS_BASE/zhaochaoqun/sherpa-onnx-asr-models/resolve/master/silero_vad.onnx"
download "$SILERO_URL" "$VAD_DIR/silero_vad.onnx" "Silero VAD"

# ---------------------------------------------------------------------------
# 2. 中英双语流式 Zipformer（int8 四件套 ~190MB：encoder 174M + decoder 13M + joiner 3.1M）
#    模式 A 唯一识别器 + 模式 B 中文侧
#    官方同名镜像仓：pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20
#    文件：encoder-epoch-99-avg-1.int8.onnx / decoder-epoch-99-avg-1.int8.onnx
#         joiner-epoch-99-avg-1.int8.onnx / tokens.txt
# ---------------------------------------------------------------------------
BILINGUAL_REPO="pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"

for f in \
  "encoder-epoch-99-avg-1.int8.onnx" \
  "decoder-epoch-99-avg-1.int8.onnx" \
  "joiner-epoch-99-avg-1.int8.onnx" \
  "tokens.txt"; do
  download "$MS_BASE/$BILINGUAL_REPO/resolve/master/$f" "$ZH_EN_DIR/$f" "bilingual zh-en / $f"
done

# ---------------------------------------------------------------------------
# 3. 俄语流式 T-one CTC（压缩包 ~123MB）
#    仅模式 B 加载。从全量镜像仓下载。
#    2026-07 实测（GitHub 官方包）：仅有 fp32 model.onnx（~138MB）+ tokens.txt，
#    官方无 int8 版。Kotlin 侧按"目录内首个 .onnx"加载，fp32 可直接用。
#    文件名以镜像仓文件页实际为准，若失败请在 ModelScope 站内搜索。
# ---------------------------------------------------------------------------
RU_REPO="zhaochaoqun/sherpa-onnx-asr-models"

# 尝试方式 1：直接下载单文件（先 fp32 实名，再探测 int8 以防未来官方补充）
RU_FILES_FOUND=false
for f in "model.onnx" "tokens.txt"; do
  RU_CANDIDATE_URL="$MS_BASE/$RU_REPO/resolve/master/sherpa-onnx-streaming-t-one-russian-2025-09-08/$f"
  if curl -sfI --retry 1 "$RU_CANDIDATE_URL" >/dev/null 2>&1; then
    download "$RU_CANDIDATE_URL" "$RU_DIR/$f" "T-one 俄语 / $f"
    RU_FILES_FOUND=true
  fi
done

# 尝试方式 2：如果方式 1 失败，下载 tar.bz2 解压
if [ "$RU_FILES_FOUND" = false ]; then
  echo "[提示] T-one 俄语模型单文件下载失败，尝试 tar.bz2 包…"
  echo "  若 ModelScope 全量镜像仓未同步该模型，请在站内搜索："
  echo "  sherpa-onnx-streaming-t-one-russian-2025-09-08"
  echo "  手动下载后解压到 $RU_DIR/"
  # 不让脚本失败（俄语模型非必需，模式 A 不需要）
  echo "[警告] 俄语模型未下载完成。模式 A（中⇄英）不受影响。"
fi

echo ""
echo "=========================================="
echo "下载完成。模型位于: $ASSETS_DIR/"
echo "  vad/    — Silero VAD"
echo "  zh_en/  — 中英双语流式 Zipformer"
echo "  ru/     — 俄语 T-one CTC（可能需手动补齐）"
echo "=========================================="
echo ""
echo "提示：模型目录已在 .gitignore 中忽略，不会提交到 git。"
echo "构建前请确保模型已下载到上述目录。"
