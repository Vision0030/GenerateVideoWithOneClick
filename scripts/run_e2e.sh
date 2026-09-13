#!/bin/bash
# 编译并运行渲染链路端到端验证。
# 复用 App 的 KBTimelineBuilder / KBVideoCompositor / KBExporter，用 Mac Catalyst 目标
# 编成命令行程序（这些类依赖 UIKit，所以走 macabi 而不是纯 macOS）。
#
# 用法：
#   scripts/run_e2e.sh                # 跑 bundle 内全部模板
#   scripts/run_e2e.sh travel_fast    # 只跑指定模板
#   E2E_REPEAT=10 scripts/run_e2e.sh travel_fast   # 重复跑，用于排查偶发问题
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK=$(xcrun --sdk macosx --show-sdk-path)
SDK_VER=$(basename "$SDK" | sed -e 's/^MacOSX//' -e 's/\.sdk$//')
ARCH=$(uname -m)
RES_DIR=GenerateVideoWithOneClick
OUT_DIR=build/e2e
REPEAT=${E2E_REPEAT:-1}
mkdir -p "$OUT_DIR"

echo "== 编译 e2e_test（target ${ARCH}-apple-ios${SDK_VER}-macabi，SDK ${SDK_VER}）=="
clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT_DIR/ModuleCache" -O1 -g \
  -target "${ARCH}-apple-ios${SDK_VER}-macabi" -isysroot "$SDK" \
  -F "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$RES_DIR" \
  scripts/e2e_test.m \
  "$RES_DIR/KBTemplate.m" "$RES_DIR/KBMediaAsset.m" "$RES_DIR/KBTimelineBuilder.m" \
  "$RES_DIR/KBVideoCompositor.m" "$RES_DIR/KBExporter.m" \
  -framework Foundation -framework AVFoundation -framework CoreImage -framework CoreMedia \
  -framework CoreGraphics -framework CoreVideo -framework ImageIO -framework Metal \
  -framework Photos -framework UIKit \
  -o "$OUT_DIR/e2e_test"

# 模板清单：默认取 bundle 内所有带 clip_beats 的 JSON（与 KBTemplate +templatesInBundle: 同规则）
if [ "$#" -gt 0 ]; then
  TEMPLATES=("$@")
else
  TEMPLATES=($(python3 - "$RES_DIR" <<'PY'
import glob, json, os, sys
names = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (ValueError, OSError):
        continue
    if isinstance(data, dict) and data.get("id") and data.get("bpm") and data.get("clip_beats"):
        names.append(os.path.splitext(os.path.basename(path))[0])
print(" ".join(names))
PY
))
fi

failures=0
for tpl in "${TEMPLATES[@]}"; do
  for ((i = 1; i <= REPEAT; i++)); do
    echo
    if [ "$REPEAT" -gt 1 ]; then
      echo "== ${tpl}（第 $i/$REPEAT 次）=="
    fi
    if ! "$OUT_DIR/e2e_test" "$RES_DIR" "$tpl"; then
      failures=$((failures + 1))
    fi
  done
done

echo
if [ "$failures" -eq 0 ]; then
  echo "== 全部模板通过 ✓（${TEMPLATES[*]}）=="
else
  echo "== 有 $failures 个模板验证失败 ✗ =="
fi
exit "$failures"
