#!/usr/bin/env bash
# ============================================================================
# wsl-command-init —— 新 WSL 环境一键初始化脚本
#
# 功能：用各版本管理器安装当前最新版本，并把每个工具「官方文档要求」的
#       ~/.bashrc 集成内容原样写入（不做额外发明；重复执行不会重复追加）。
#   1. sdkman + 最新 Oracle Java
#   2. fnm     + 最新 Node.js
#   3. gvm     + 最新 Go
#   4. pyenv   + 最新 Python
#
# 用法：
#   bash setup.sh                 # 全部安装
#   bash setup.sh --java --node   # 只安装指定项
#   bash setup.sh --no-rc         # 不写 ~/.bashrc
#   bash setup.sh --no-apt        # 跳过系统依赖（apt）安装
#   bash setup.sh -h | --help     # 帮助
#
# 隔离测试（不影响现有系统）：
#   HOME=/tmp/test-home bash setup.sh --no-apt
#   或覆盖：SDKMAN_DIR / FNM_DIR / GVM_ROOT / PYENV_ROOT / RC_FILE
#
# 镜像（默认官方源，国内网络可自行用环境变量指定镜像）：
#   SDKMAN_CANDIDATES_API  FNM_NODE_DIST_MIRROR
#   GO_BINARY_BASE_URL     PYTHON_BUILD_MIRROR_URL
# ============================================================================
set -eo pipefail

# ------------------------------ 配置（可用环境变量覆盖） ------------------------------
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
GVM_ROOT="${GVM_ROOT:-$HOME/.gvm}"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
RC_FILE="${RC_FILE:-$HOME/.bashrc}"

SDKMAN_CANDIDATES_API="${SDKMAN_CANDIDATES_API:-https://api.sdkman.io/2}"
FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-}"
GO_BINARY_BASE_URL="${GO_BINARY_BASE_URL:-https://go.dev/dl}"
GO_VERSION_URL="${GO_VERSION_URL:-https://go.dev/VERSION?m=text}"
PYTHON_BUILD_MIRROR_URL="${PYTHON_BUILD_MIRROR_URL:-https://www.python.org/ftp/python}"
# 用路径替换镜像（如国内镜像按版本路径提供）时需跳过校验和
PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM="${PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM:-0}"

# ------------------------------ 参数解析 ------------------------------
DO_JAVA=0; DO_NODE=0; DO_GO=0; DO_PYTHON=0
DO_APT=1; DO_RC=1

usage() {
  cat <<'EOF'
用法: bash setup.sh [选项]

选项:
  --java            安装 sdkman 并安装最新 Oracle Java
  --node            安装 fnm 并安装最新 Node.js
  --go              安装 gvm 并安装最新 Go
  --python          安装 pyenv 并安装最新 Python
  --no-apt          跳过系统依赖安装（apt-get）
  --no-rc           不写入 ~/.bashrc
  -h, --help        显示本帮助

不带任何选项时默认全部安装。

环境变量（目录/镜像覆盖）:
  SDKMAN_DIR FNM_DIR GVM_ROOT PYENV_ROOT RC_FILE
  SDKMAN_CANDIDATES_API FNM_NODE_DIST_MIRROR
  GO_BINARY_BASE_URL PYTHON_BUILD_MIRROR_URL
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --java)       DO_JAVA=1 ;;
    --node)       DO_NODE=1 ;;
    --go)         DO_GO=1 ;;
    --python)     DO_PYTHON=1 ;;
    --no-apt)     DO_APT=0 ;;
    --no-rc)      DO_RC=0 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [ "$DO_JAVA$DO_NODE$DO_GO$DO_PYTHON" = "0000" ]; then
  DO_JAVA=1; DO_NODE=1; DO_GO=1; DO_PYTHON=1
fi

# ------------------------------ 工具函数 ------------------------------
log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# 关闭 errexit 再 source/eval 工具脚本，避免其内部非零返回值触发退出
safe_source() { set +e; source "$1" >/dev/null 2>&1; local rc=$?; set -e; return "$rc"; }
safe_eval()   { set +e; eval "$1" >/dev/null 2>&1; local rc=$?; set -e; return "$rc"; }

# ------------------------------ 系统依赖 ------------------------------
install_system_deps() {
  log "安装系统依赖（apt-get）..."
  sudo -v || err "需要 sudo 权限（可加 --no-apt 跳过）"
  sudo apt-get update -qq
  sudo apt-get install -y \
    curl git unzip zip ca-certificates \
    build-essential xz-utils bzip2 bison tk-dev \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev libffi-dev liblzma-dev
  if ! command -v hexdump >/dev/null 2>&1; then
    if apt-cache show bsdmainutils >/dev/null 2>&1; then
      sudo apt-get install -y bsdmainutils
    else
      sudo apt-get install -y bsdutils
    fi
  fi
}

# ------------------------------ sdkman + 最新 Oracle Java ------------------------------
install_sdkman() {
  if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
    log "安装 sdkman 到 $SDKMAN_DIR ..."
    export SDKMAN_DIR
    curl -fsSL --retry 3 "https://get.sdkman.io" | bash || err "sdkman 安装失败，请检查网络"
  fi
  safe_source "$SDKMAN_DIR/bin/sdkman-init.sh" || err "sdkman 初始化失败"
  export SDKMAN_CANDIDATES_API
  # 自动应答，避免安装时交互提问
  local cfg="$SDKMAN_DIR/etc/config"
  if grep -q '^sdkman_auto_answer=' "$cfg" 2>/dev/null; then
    sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$cfg"
  else
    echo 'sdkman_auto_answer=true' >> "$cfg"
  fi
  log "sdkman 就绪: $(sdk version 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
}

install_latest_java() {
  local id
  id="$(sdk list java 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | awk -F'|' '/-oracle$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); print $NF }' \
        | sort -V | tail -1)"
  [ -n "$id" ] || err "无法从 sdkman 获取最新 Oracle Java 版本"
  log "安装 Oracle Java $id ..."
  sdk install java "$id"
  log "Java 安装完成: $("$SDKMAN_DIR/candidates/java/current/bin/java" -version 2>&1 | head -1)"
}

# ------------------------------ fnm + 最新 Node.js ------------------------------
install_fnm() {
  if [ ! -x "$FNM_DIR/fnm" ]; then
    log "安装 fnm 到 $FNM_DIR ..."
    mkdir -p "$FNM_DIR"
    local arch=""
    case "$(uname -m)" in
      x86_64|amd64) arch="" ;;
      aarch64|arm64) arch="-arm64" ;;
      *) err "不支持的 CPU 架构: $(uname -m)" ;;
    esac
    command -v unzip >/dev/null 2>&1 || err "缺少 unzip"
    local tmp; tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" EXIT
    curl -fsSL --retry 3 "https://github.com/Schniz/fnm/releases/latest/download/fnm-linux${arch}.zip" -o "$tmp/fnm.zip" \
      || err "fnm 下载失败，请检查网络"
    unzip -oq "$tmp/fnm.zip" -d "$FNM_DIR"
    chmod +x "$FNM_DIR/fnm"
    rm -rf "$tmp"
    trap - EXIT
  fi
  export PATH="$FNM_DIR:$PATH" FNM_NODE_DIST_MIRROR
  fnm --version >/dev/null 2>&1 || err "fnm 不可用"
  log "fnm 就绪: $(fnm --version)"
}

install_latest_node() {
  local ver
  ver="$(fnm ls-remote | tail -1)"
  [ -n "$ver" ] || err "无法获取最新 Node.js 版本"
  log "安装 Node.js $ver ..."
  fnm install "$ver"
  fnm default "$ver"
  log "Node.js 安装完成: $(fnm exec --using="$ver" -- node --version)"
}

# ------------------------------ gvm + 最新 Go ------------------------------
install_gvm() {
  if [ ! -s "$GVM_ROOT/scripts/gvm" ]; then
    log "安装 gvm 到 $GVM_ROOT ..."
    if ! bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer"); then
      err "gvm 安装失败，请检查网络"
    fi
  fi
  export GVM_ROOT
  safe_source "$GVM_ROOT/scripts/gvm" || err "gvm 加载失败"
  log "gvm 就绪"
}

install_latest_go() {
  export GO_BINARY_BASE_URL
  local ver
  ver="$(curl -fsSL --retry 3 "$GO_VERSION_URL" | head -1)"
  [ -n "$ver" ] || err "无法获取最新 Go 版本"
  log "安装 Go $ver ..."
  # -B：只从二进制安装，避免源码完整编译
  gvm install "$ver" -B
  gvm use "$ver" --default
  log "Go 安装完成: $("$GVM_ROOT/gos/$ver/bin/go" version)"
}

# ------------------------------ pyenv + 最新 Python ------------------------------
install_pyenv() {
  if [ ! -s "$PYENV_ROOT/bin/pyenv" ]; then
    log "安装 pyenv 到 $PYENV_ROOT ..."
    export PYENV_ROOT
    curl -fsSL --retry 3 "https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer" | bash \
      || err "pyenv 安装失败，请检查网络"
  fi
  export PATH="$PYENV_ROOT/bin:$PATH"
  safe_eval "$(pyenv init - bash)" || true
  pyenv --version >/dev/null 2>&1 || err "pyenv 不可用"
  log "pyenv 就绪: $(pyenv --version)"
}

install_latest_python() {
  export PYTHON_BUILD_MIRROR_URL PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM
  local ver
  ver="$(pyenv install --list \
         | sed 's/^[[:space:]]*//' \
         | grep -E '^3\.[0-9]+\.[0-9]+$' \
         | sort -V | tail -1)"
  [ -n "$ver" ] || err "无法获取最新 Python 版本"
  log "安装 Python $ver ..."
  pyenv install "$ver"
  pyenv global "$ver"
  log "Python 安装完成: $("$PYENV_ROOT/versions/$ver/bin/python" --version)"
}

# ------------------------------ bashrc 集成 ------------------------------
# 写入各工具「官方文档」要求的内容（原样），用 marker 包裹以便幂等/清理。
write_rc() {
  local marker="# >>> wsl-command-init >>>"
  if grep -qF "$marker" "$RC_FILE" 2>/dev/null; then
    log "$RC_FILE 已包含初始化块，跳过写入"
    return 0
  fi
  mkdir -p "$(dirname "$RC_FILE")"
  cat >> "$RC_FILE" <<'EOF'

# >>> wsl-command-init >>>

# --- sdkman（官方文档）---
export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# --- pyenv（官方文档）---
export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# --- pyenv-virtualenv 插件（官方文档）---
eval "$(pyenv virtualenv-init -)"

# --- gvm（官方文档）---
export GVM_ROOT="${GVM_ROOT:-$HOME/.gvm}"
[[ -s "$GVM_ROOT/scripts/gvm" ]] && source "$GVM_ROOT/scripts/gvm"

# --- fnm（官方文档）---
FNM_PATH="${FNM_DIR:-$HOME/.local/share/fnm}"
if [ -d "$FNM_PATH" ]; then
  export PATH="$FNM_PATH:$PATH"
  # 官方默认 `fnm env`（不启用 --use-on-cd，避免与 gvm 同时 hook cd() 冲突）
  eval "$(fnm env)"
fi

# <<< wsl-command-init <<<
EOF
  log "已写入 $RC_FILE（重新打开终端或执行 source $RC_FILE 生效）"
}

# ------------------------------ 主流程 ------------------------------
main() {
  [ "$DO_APT" = 1 ] && install_system_deps
  [ "$DO_JAVA" = 1 ]   && { install_sdkman; install_latest_java; }
  [ "$DO_NODE" = 1 ]   && { install_fnm;    install_latest_node; }
  [ "$DO_GO" = 1 ]     && { install_gvm;    install_latest_go; }
  [ "$DO_PYTHON" = 1 ] && { install_pyenv;  install_latest_python; }
  [ "$DO_RC" = 1 ]     && write_rc
  log "全部完成！"
}

main "$@"
