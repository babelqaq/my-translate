#!/usr/bin/env bash
# ============================================================================
# 【VPN 专用】从 GitHub 官方源一键下载 Phase A 所需的全部外部资源：
#   1. Silero VAD          → android/app/src/main/assets/models/vad/
#   2. 中英双语流式 Zipformer → android/app/src/main/assets/models/zh_en/
#   3. T-one 俄语流式 CTC    → android/app/src/main/assets/models/ru/
#   4. sherpa-onnx AAR      → android/app/libs/
#
# 前提：已开启 VPN（能访问 github.com / objects.githubusercontent.com）
#
# 用法（在项目根目录的 Git Bash 中执行）：
#   bash tools/fetch_models_github.sh
#
# 特性：
#   - 已存在且非空的文件自动跳过（可重复运行，增量友好）
#   - curl 断点续传（-C -），VPN 断线重跑即可继续
#   - 压缩包下载到 tools/.cache/ 并保留，解压失败可重试不用重新下载
#
# 注意：本脚本仅供本机手动运行。CI 禁止使用 GitHub 源（INV-MIRROR），
#       CI 走 tools/fetch_models.sh（ModelScope）。
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 可调参数
# ---------------------------------------------------------------------------
AAR_VERSION="1.12.14"   # 已核实该版本 Release 存在（2025-09-18 发布）
GH="https://github.com/k2-fsa/sherpa-onnx/releases/download"

# 模型统一挂在 asr-models 这个 tag 下（sherpa-onnx 官方惯例）
MODELS_TAG="$GH/asr-models"

BILINGUAL_NAME="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
RU_NAME="sherpa-onnx-streaming-t-one-russian-2025-09-08"

# ---------------------------------------------------------------------------
# 目录
# ---------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/android/app/src/main/assets/models"
VAD_DIR="$ASSETS_DIR/vad"
ZH_EN_DIR="$ASSETS_DIR/zh_en"
RU_DIR="$ASSETS_DIR/ru"
LIBS_DIR="$ROOT_DIR/android/app/libs"
CACHE_DIR="$ROOT_DIR/tools/.cache"

mkdir -p "$VAD_DIR" "$ZH_EN_DIR" "$RU_DIR" "$LIBS_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
download() {
  # download <url> <dest> <label>
  local url="$1" dest="$2" label="$3"
  if [ -f "$dest" ] && [ -s "$dest" ]; then
    echo "[跳过] $label（已存在: $(du -h "$dest" | cut -f1)）"
    return 0
  fi
  echo "[下载] $label"
  echo "  来源: $url"
  # -C - 断点续传；--retry 网络抖动自动重试
  curl -fL -C - --retry 5 --retry-delay 5 --connect-timeout 20 \
       -o "$dest.part" "$url"
  mv -f "$dest.part" "$dest"
  echo "  完成: $(du -h "$dest" | cut -f1)"
}

extract_pick() {
  # extract_pick <tar.bz2 路径> <解压出的顶层目录名> <目标目录> <文件...>
  # 只把需要的文件挑出来放进目标目录，临时解压目录用后即删
  local archive="$1" topdir="$2" destdir="$3"
  shift 3
  local tmp="$CACHE_DIR/extract_$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  echo "  解压中: $(basename "$archive")"
  tar -xjf "$archive" -C "$tmp"
  local missing=0
  for f in "$@"; do
    if [ -f "$tmp/$topdir/$f" ]; then
      cp -f "$tmp/$topdir/$f" "$destdir/$(basename "$f")"
      echo "  提取: $f → $destdir/"
    else
      echo "  [警告] 压缩包内未找到: $f"
      missing=1
    fi
  done
  if [ "$missing" = 1 ]; then
    echo "  [提示] 压缩包实际内容如下（供核对文件名）："
    (cd "$tmp/$topdir" && ls -la)
  fi
  rm -rf "$tmp"
}

all_exist() {
  # all_exist <目录> <文件...>：全部存在且非空返回 0
  local dir="$1"; shift
  for f in "$@"; do
    [ -s "$dir/$f" ] || return 1
  done
  return 0
}

echo "=============================================="
echo " sherpa-onnx 资源下载（GitHub 官方源，需 VPN）"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# 0. 连通性自检（快速失败，避免半途卡死）
# ---------------------------------------------------------------------------
echo "[检查] GitHub 连通性…"
if ! curl -fsI --connect-timeout 10 "https://github.com" >/dev/null 2>&1; then
  echo "[错误] 无法访问 github.com —— 请确认 VPN 已开启后重试。"
  echo "       若 VPN 走本地代理端口，可先执行（按实际端口改）："
  echo "       export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890"
  exit 1
fi
echo "  OK"
echo ""

# ---------------------------------------------------------------------------
# 1. Silero VAD（~2MB，单文件直链）
# ---------------------------------------------------------------------------
download "$MODELS_TAG/silero_vad.onnx" "$VAD_DIR/silero_vad.onnx" "Silero VAD"
echo ""

# ---------------------------------------------------------------------------
# 2. 中英双语流式 Zipformer
#    压缩包 ~488MB 属正常（官方包内含 fp32 315M + int8 174M + 测试音频），
#    只提取 int8 四件套（~190MB）进 assets，fp32 与测试音频不进 APK。
# ---------------------------------------------------------------------------
ZH_EN_FILES=(
  "encoder-epoch-99-avg-1.int8.onnx"
  "decoder-epoch-99-avg-1.int8.onnx"
  "joiner-epoch-99-avg-1.int8.onnx"
  "tokens.txt"
)
if all_exist "$ZH_EN_DIR" "${ZH_EN_FILES[@]}"; then
  echo "[跳过] 中英双语模型（4 个文件均已存在）"
else
  download "$MODELS_TAG/$BILINGUAL_NAME.tar.bz2" \
           "$CACHE_DIR/$BILINGUAL_NAME.tar.bz2" \
           "中英双语流式 Zipformer 压缩包"
  extract_pick "$CACHE_DIR/$BILINGUAL_NAME.tar.bz2" "$BILINGUAL_NAME" \
               "$ZH_EN_DIR" "${ZH_EN_FILES[@]}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. T-one 俄语流式 CTC（压缩包 ~123MB）
#    2026-07 实测：包内仅有 fp32 model.onnx（~138MB）+ tokens.txt，
#    官方未提供 int8 版本。脚本仍先探测 int8（未来官方若补充），
#    否则取 fp32 model.onnx；Kotlin 侧按"目录内首个 .onnx"加载，
#    两者均兼容——"未找到 model.int8.onnx"的警告可忽略。
# ---------------------------------------------------------------------------
if [ -s "$RU_DIR/tokens.txt" ] && { [ -s "$RU_DIR/model.int8.onnx" ] || [ -s "$RU_DIR/model.onnx" ]; }; then
  echo "[跳过] T-one 俄语模型（已存在）"
else
  download "$MODELS_TAG/$RU_NAME.tar.bz2" \
           "$CACHE_DIR/$RU_NAME.tar.bz2" \
           "T-one 俄语流式 CTC 压缩包"
  # 先尝试 int8 + tokens；提取函数会对缺失文件打印包内清单
  extract_pick "$CACHE_DIR/$RU_NAME.tar.bz2" "$RU_NAME" \
               "$RU_DIR" "model.int8.onnx" "model.onnx" "tokens.txt"
  # 两个 onnx 至少要有一个
  if [ ! -s "$RU_DIR/model.int8.onnx" ] && [ ! -s "$RU_DIR/model.onnx" ]; then
    echo "[警告] 俄语模型 onnx 提取失败，请按上方包内清单手动核对文件名。"
    echo "       模式 A（中⇄英）不受影响。"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# 4. sherpa-onnx AAR（~38MB，放 android/app/libs/，此文件要提交 git）
#    资产名已核实：sherpa-onnx-1.12.14.aar（勿用 -rknn / static-link 变体）
# ---------------------------------------------------------------------------
download "$GH/v$AAR_VERSION/sherpa-onnx-$AAR_VERSION.aar" \
         "$LIBS_DIR/sherpa-onnx-$AAR_VERSION.aar" \
         "sherpa-onnx AAR v$AAR_VERSION"
echo ""

# ---------------------------------------------------------------------------
# 结果汇总
# ---------------------------------------------------------------------------
echo "=============================================="
echo " 下载结果汇总"
echo "=============================================="
for d in "$VAD_DIR" "$ZH_EN_DIR" "$RU_DIR" "$LIBS_DIR"; do
  echo ""
  echo "  $d"
  if ls "$d"/* >/dev/null 2>&1; then
    (cd "$d" && du -h -- * 2>/dev/null | sed 's/^/    /')
  else
    echo "    （空）"
  fi
done
echo ""
echo "----------------------------------------------"
echo "后续步骤提醒："
echo "  1. AAR 需要提交 git：git add android/app/libs/*.aar"
echo "  2. 模型目录已被 .gitignore 忽略，不提交（符合预期）"
echo "  3. 压缩包缓存在 tools/.cache/，确认无误后可删除释放空间"
echo "----------------------------------------------"
