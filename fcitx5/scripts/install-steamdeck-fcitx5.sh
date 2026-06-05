#!/bin/bash
# Steam Deck / SteamOS helper for VoCoType Fcitx5 installation.
# - Installs required Arch packages
# - Applies known Fcitx5 compatibility patches idempotently
# - Runs the upstream install-fcitx5.sh with sane defaults
# - Writes the preferred Rime schema for VoCoType
#
# Usage:
#   bash fcitx5/scripts/install-steamdeck-fcitx5.sh
#   bash fcitx5/scripts/install-steamdeck-fcitx5.sh --skip-audio
#
# Optional env vars:
#   VOCOTYPE_RIME_SCHEMA=double_pinyin_flypy

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
INSTALL_SCRIPT="$PROJECT_DIR/fcitx5/scripts/install-fcitx5.sh"
DEFAULT_RIME_SCHEMA="${VOCOTYPE_RIME_SCHEMA:-double_pinyin}"
SKIP_AUDIO=0

usage() {
    cat <<'EOF'
Usage:
  bash fcitx5/scripts/install-steamdeck-fcitx5.sh [--skip-audio]

Options:
  --skip-audio   Skip interactive audio setup inside install-fcitx5.sh.

Environment:
  VOCOTYPE_RIME_SCHEMA   Preferred schema written to ~/.config/vocotype/rime/user.yaml
                         Default: double_pinyin
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-audio)
            SKIP_AUDIO=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少命令: $1" >&2
        exit 1
    }
}

apply_known_patches() {
    python - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])

patches = {
    project / "fcitx5/addon/vocotype.h": [
        (
            "#include <fcitx-utils/eventloopinterface.h>",
            "#include <fcitx-utils/event.h>",
        ),
    ],
    project / "fcitx5/addon/vocotype.cpp": [
        (
            "fcitx::readAsIni(config_, fcitx::StandardPathsType::PkgConfig,",
            "fcitx::readAsIni(config_, fcitx::StandardPath::Type::PkgConfig,",
        ),
        (
            "if (!fcitx::safeSaveAsIni(config_, fcitx::StandardPathsType::PkgConfig,",
            "if (!fcitx::safeSaveAsIni(config_, fcitx::StandardPath::Type::PkgConfig,",
        ),
    ],
    project / "fcitx5/scripts/install-fcitx5.sh": [
        (
            'if [ ! -x "$PYTHON" ]; then\n'
            '    echo "错误: 未找到 Python 可执行文件: $PYTHON"\n'
            '    exit 1\n'
            'fi\n'
            '\n'
            '# 安装依赖\n',
            'if [ ! -x "$PYTHON" ]; then\n'
            '    echo "错误: 未找到 Python 可执行文件: $PYTHON"\n'
            '    exit 1\n'
            'fi\n'
            '\n'
            '# Fcitx5 后端不依赖 IBus 的 gi/PyGObject 栈；直接复用仓库根 requirements.txt\n'
            '# 会在 Python 3.12 上额外触发 pycairo/PyGObject 构建，导致非必需的系统依赖失败。\n'
            'FCITX5_REQUIREMENTS="$(mktemp)"\n'
            'grep -v \'^PyGObject\' "$PROJECT_DIR/requirements.txt" > "$FCITX5_REQUIREMENTS"\n'
            'trap \'rm -f "$FCITX5_REQUIREMENTS"\' EXIT\n'
            '\n'
            '# 安装依赖\n',
        ),
        (
            'echo "  $PYTHON -m pip install -r $PROJECT_DIR/requirements.txt pyrime"\n',
            'echo "  grep -v \'^PyGObject\' $PROJECT_DIR/requirements.txt | $PYTHON -m pip install -r /dev/stdin"\n'
            '        echo "  $PYTHON -m pip install pyrime"\n',
        ),
        (
            'uv pip install -r "$PROJECT_DIR/requirements.txt" --python "$PYTHON"\n',
            'uv pip install -r "$FCITX5_REQUIREMENTS" --python "$PYTHON"\n',
        ),
        (
            '"$PYTHON" -m pip install -r "$PROJECT_DIR/requirements.txt"\n',
            '"$PYTHON" -m pip install -r "$FCITX5_REQUIREMENTS"\n',
        ),
    ],
}

for path, replacements in patches.items():
    text = path.read_text(encoding="utf-8")
    original = text
    for old, new in replacements:
        if old in text:
            text = text.replace(old, new)
    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"patched: {path}")
    else:
        print(f"ok: {path}")
PY
}

write_vocotype_rime_schema() {
    mkdir -p "$HOME/.config/vocotype/rime"
    cat > "$HOME/.config/vocotype/rime/user.yaml" <<EOF
# VoCoType RIME 用户配置
var:
  previously_selected_schema: "$DEFAULT_RIME_SCHEMA"
EOF
}

require_cmd sudo
require_cmd pacman
require_cmd bash

if command -v steamos-readonly >/dev/null 2>&1; then
    sudo steamos-readonly disable
fi

sudo pacman -S --needed \
    fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool fcitx5-rime \
    git base-devel cmake pkgconf nlohmann-json python python-uv

apply_known_patches

INSTALL_ARGS=()
if [[ "$SKIP_AUDIO" -eq 1 ]]; then
    INSTALL_ARGS+=(--skip-audio)
fi

# Feed defaults:
# 1) SLM disabled
# 2) user venv
# 3) default Rime choice (we overwrite schema after install)
printf '\n\n\n' | bash "$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}"

write_vocotype_rime_schema

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
fi

cat <<EOF

Steam Deck 安装脚本执行完成。

已强制写入 VoCoType Rime 方案:
  ~/.config/vocotype/rime/user.yaml
  schema = $DEFAULT_RIME_SCHEMA

下一步建议:
  1. 若这次使用了 --skip-audio，手动运行音频配置:
       ~/.local/share/vocotype-fcitx5/.venv/bin/python ~/.local/share/vocotype-fcitx5/scripts/setup-audio.py
  2. 启动后台服务:
       systemctl --user enable --now vocotype-fcitx5-backend.service
  3. 重启 Fcitx5:
       fcitx5 -r
  4. 在 fcitx5-configtool 里添加 VoCoType 输入法

EOF
