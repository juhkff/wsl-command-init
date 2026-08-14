#!/usr/bin/env bash
# ============================================================================
# wsl-command-init —— 新 WSL 环境一键初始化脚本
#
# 功能（每项安装完成后自动安装当前最新版本）：
#   1. sdkman + 最新 Oracle Java（Vendor = Oracle 的最新 Release）
#   2. fnm   + 最新 Node.js
#   3. gvm   + 最新 Go
#   4. pyenv + 最新 Python
#   并写入 ~/.bashrc 集成（幂等，重复执行不会产生重复配置）
#
# 用法：
#   bash setup.sh                 # 全部安装
#   bash setup.sh --java --node   # 只安装指定项
#   bash setup.sh --print-versions # 只打印各工具当前可安装的最新版本（不安装）
#   bash setup.sh --no-apt        # 跳过系统依赖安装（apt）
#   bash setup.sh --no-rc         # 不写 ~/.bashrc
#
# 隔离测试（不影响现有系统）：
#   HOME=/tmp/test-home bash setup.sh   # 所有工具装到临时 HOME 下
#   或单独覆盖：SDKMAN_DIR / FNM_DIR / GVM_ROOT / PYENV_ROOT / RC_FILE
#
# 镜像说明（可用同名环境变量覆盖）：
#   - sdkman 国内暂无公共 API 镜像，默认官方 https://api.sdkman.io/2
#   - fnm   默认自动探测首个可用镜像（官方 → 清华 → 华为云 → npmmirror → 腾讯云）。
#           注意：华为云/npmmirror/腾讯云对 fnm 的 rustls TLS 栈不兼容
#           （服务器仅支持 TLS1.2 且拒绝 h2，rustls 客户端请求报错或挂起），
#           官方 nodejs.org 与清华镜像实测可用。
#   - gvm   默认 golang.google.cn（Google 官方国内镜像）
#   - pyenv 默认 npmmirror https://registry.npmmirror.com/-/binary/python
#            （新版 python-build 需配合 PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1）
# ============================================================================
# 注意：不使用 `set -u`（nounset）。sdkman-init.sh、gvm 等工具脚本内部依赖
# “未定义变量按空处理”的宽松行为，nounset 下 source/调用会直接 fatal 退出。
set -eo pipefail

# ------------------------------ 配置（可用环境变量覆盖） ------------------------------
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
GVM_ROOT="${GVM_ROOT:-$HOME/.gvm}"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
RC_FILE="${RC_FILE:-$HOME/.bashrc}"

SDKMAN_CANDIDATES_API="${SDKMAN_CANDIDATES_API:-https://api.sdkman.io/2}"
# fnm 镜像：优先使用用户显式设置的 FNM_NODE_DIST_MIRROR；未设置时按
# NODE_MIRROR_CANDIDATES 顺序自动探测第一个可用的（用 fnm 实测，见 pick_node_mirror）。
# 华为云等镜像仅支持 TLS1.2 且拒绝 h2，与 fnm 的 rustls TLS 栈不兼容，
# 因此排在候选列表末尾，且探测时用 timeout 兜底防止挂起。
FNM_NODE_DIST_MIRROR_USER="${FNM_NODE_DIST_MIRROR:-}"
NODE_MIRROR_CANDIDATES=(
  "https://nodejs.org/dist"
  "https://mirrors.tuna.tsinghua.edu.cn/nodejs-release"
  "https://mirrors.huaweicloud.com/nodejs/"
  "https://registry.npmmirror.com/-/binary/node"
  "https://mirrors.tencent.com/nodejs-release"
)
GO_BINARY_BASE_URL="${GO_BINARY_BASE_URL:-https://golang.google.cn/dl}"
GO_VERSION_URL="${GO_VERSION_URL:-https://golang.google.cn/VERSION?m=text}"
# Python 源码下载镜像。新版 python-build 的 PYTHON_BUILD_MIRROR_URL 只接受
# “按 sha256 命名”的镜像（如 pyenv.github.io），华为云/npmmirror 这类
# “按版本路径”镜像需配合 PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1 使用
# （URL 改为路径替换模式，下载后的校验和验证仍然进行）。
PYTHON_BUILD_MIRROR_URL="${PYTHON_BUILD_MIRROR_URL:-https://registry.npmmirror.com/-/binary/python}"
PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM="${PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM:-1}"

# ------------------------------ 参数解析 ------------------------------
DO_JAVA=0; DO_NODE=0; DO_GO=0; DO_PYTHON=0
DO_APT=1; DO_RC=1; PRINT_ONLY=0

usage() {
  cat <<'EOF'
用法: bash setup.sh [选项]

选项:
  --java            安装 sdkman 并安装最新 Oracle Java
  --node            安装 fnm 并安装最新 Node.js
  --go              安装 gvm 并安装最新 Go
  --python          安装 pyenv 并安装最新 Python
  --print-versions  只打印可安装的最新版本号，不进行安装
  --no-apt          跳过系统依赖安装（apt-get）
  --no-rc           不写入 ~/.bashrc
  -h, --help        显示本帮助

不带任何选项时默认全部安装。

环境变量（用于镜像/目录覆盖，详见脚本头部注释）:
  SDKMAN_DIR FNM_DIR GVM_ROOT PYENV_ROOT RC_FILE
  SDKMAN_CANDIDATES_API FNM_NODE_DIST_MIRROR
  GO_BINARY_BASE_URL GO_VERSION_URL PYTHON_BUILD_MIRROR_URL
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --java)          DO_JAVA=1 ;;
    --node)          DO_NODE=1 ;;
    --go)            DO_GO=1 ;;
    --python)        DO_PYTHON=1 ;;
    --print-versions) PRINT_ONLY=1 ;;
    --no-apt)        DO_APT=0 ;;
    --no-rc)         DO_RC=0 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# 未指定任何工具时默认全部
if [ "$DO_JAVA$DO_NODE$DO_GO$DO_PYTHON" = "0000" ]; then
  DO_JAVA=1; DO_NODE=1; DO_GO=1; DO_PYTHON=1
fi

# ------------------------------ 工具函数 ------------------------------
log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# 完整读取输入后取第一行输出。
# 不要用 `cmd | head -1` / `cmd | sed -n '1p'`：上游写管道时可能因下游提前
# 关闭而 SIGPIPE(141)，在 `set -o pipefail` 下会让整个脚本意外退出。
first_line() {
  local input
  input="$(cat)"
  printf '%s\n' "${input%%$'\n'*}"
}

# 在关闭 errexit 的状态下 source/eval 工具脚本。
# 工具脚本（sdkman-init.sh、gvm 等）内部常有返回非零的检查命令，在
# `set -e` 下直接 source 会让整个 shell 意外退出，`|| err` 都来不及执行。
safe_source() {
  local rc=0
  set +e
  # shellcheck disable=SC1090
  source "$1" >/dev/null 2>&1
  rc=$?
  set -e
  return "$rc"
}
safe_eval() {
  local rc=0
  set +e
  eval "$1" >/dev/null 2>&1
  rc=$?
  set -e
  return "$rc"
}

# ------------------------------ 版本解析 ------------------------------
# 最新 Oracle Java：解析 `sdk list java` 输出中 Identifier 以 -oracle 结尾的最大版本
latest_oracle_java() {
  local id
  id="$(
    sdk list java 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | awk -F'|' '/-oracle/ { id=$NF; gsub(/[[:space:]]/, "", id); print id }' \
      | sort -V \
      | tail -1
  )"
  [ -n "$id" ] || err "无法从 sdkman 获取最新 Oracle Java 版本（请检查网络）"
  printf '%s\n' "$id"
}

# 最新 Node.js：fnm ls-remote 输出按版本升序，取最后一行
latest_node() {
  fnm ls-remote | tail -1
}

# 最新 Go：从官方版本文件获取，如 go1.26.5
latest_go() {
  local ver
  ver="$(curl -fsSL --retry 3 "$GO_VERSION_URL")"
  [ -n "$ver" ] || err "无法获取最新 Go 版本（请检查网络）"
  printf '%s\n' "$ver" | first_line
}

# 最新 Python：pyenv install --list 中最大的稳定 3.x 版本（排除 a/b/rc 预发布）
latest_python() {
  local ver
  ver="$(
    pyenv install --list \
      | sed 's/^[[:space:]]*//' \
      | grep -E '^3\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -1
  )"
  [ -n "$ver" ] || err "无法获取最新 Python 版本（请检查网络）"
  printf '%s\n' "$ver"
}

# ------------------------------ 系统依赖 ------------------------------
install_system_deps() {
  log "安装系统依赖（apt-get）..."
  sudo -v || err "需要 sudo 权限来安装系统依赖（可加 --no-apt 跳过）"
  sudo apt-get update -qq
  sudo apt-get install -y \
    curl git unzip zip ca-certificates \
    build-essential xz-utils bzip2 bison tk-dev \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev libffi-dev liblzma-dev
  # gvm 依赖 hexdump（旧版由 bsdmainutils 提供；部分新版 Ubuntu 改由 bsdutils 提供）
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
    if ! curl -fsSL --retry 3 "https://get.sdkman.io" | bash; then
      err "sdkman 安装失败，请检查网络后重试"
    fi
  fi
  # shellcheck disable=SC1090
  safe_source "$SDKMAN_DIR/bin/sdkman-init.sh" || err "sdkman 初始化失败"
  export SDKMAN_CANDIDATES_API
  # 开启自动应答，避免安装时交互提问
  local cfg="$SDKMAN_DIR/etc/config"
  if grep -q '^sdkman_auto_answer=' "$cfg" 2>/dev/null; then
    sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$cfg"
  else
    echo 'sdkman_auto_answer=true' >> "$cfg"
  fi
  log "sdkman 就绪: $(sdk version 2>/dev/null | grep -v '^[[:space:]]*$' | first_line)"
}

install_latest_java() {
  local id
  id="$(latest_oracle_java)"
  log "安装 Oracle Java $id（API: $SDKMAN_CANDIDATES_API）..."
  sdk install java "$id"
  local v
  v="$("$SDKMAN_DIR/candidates/java/current/bin/java" -version 2>&1 | first_line)" || true
  log "Java 安装完成: $v"
}

# ------------------------------ fnm + 最新 Node.js ------------------------------
# 选择 Node.js 下载镜像：用户显式设置过 FNM_NODE_DIST_MIRROR 则直接用；
# 否则按 NODE_MIRROR_CANDIDATES 顺序用 fnm 实测（ls-remote）选第一个可用的。
# 注意：不能只用 curl 探测 —— 华为云等镜像 curl 可访问但对 fnm 的 rustls
# TLS 栈不可用；且部分镜像会挂起，故用 timeout 兜底。
pick_node_mirror() {
  if [ -n "$FNM_NODE_DIST_MIRROR_USER" ]; then
    FNM_NODE_DIST_MIRROR="$FNM_NODE_DIST_MIRROR_USER"
    log "使用用户指定的 Node.js 镜像: $FNM_NODE_DIST_MIRROR"
    return 0
  fi
  local m
  for m in "${NODE_MIRROR_CANDIDATES[@]}"; do
    if timeout 20 env FNM_NODE_DIST_MIRROR="$m" fnm ls-remote >/dev/null 2>&1; then
      FNM_NODE_DIST_MIRROR="$m"
      log "Node.js 镜像可用: $m"
      return 0
    fi
    warn "Node.js 镜像不可用，尝试下一个: $m"
  done
  err "所有 Node.js 镜像均不可用，请检查网络（或设置 FNM_NODE_DIST_MIRROR 指定可用镜像）"
}

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
    command -v unzip >/dev/null 2>&1 || err "缺少 unzip（apt install unzip 或去掉 --no-apt）"
    local tmp; tmp="$(mktemp -d)"
    # 失败时清理临时目录。注册时即展开 $tmp（双引号）：bash 5.2.37+ 的
    # EXIT trap 在全局上下文执行，单引号注册引用函数 local 变量会失效。
    trap "rm -rf '$tmp'" EXIT
    if ! curl -fsSL --retry 3 "https://github.com/Schniz/fnm/releases/latest/download/fnm-linux${arch}.zip" -o "$tmp/fnm.zip"; then
      err "fnm 下载失败，请检查网络"
    fi
    unzip -oq "$tmp/fnm.zip" -d "$FNM_DIR"
    chmod +x "$FNM_DIR/fnm"
    rm -rf "$tmp"
    trap - EXIT
  fi
  export PATH="$FNM_DIR:$PATH"
  export FNM_NODE_DIST_MIRROR
  fnm --version >/dev/null 2>&1 || err "fnm 不可用"
  log "fnm 就绪: $(fnm --version)"
  pick_node_mirror
}

install_latest_node() {
  local ver
  ver="$(latest_node)"
  log "安装 Node.js $ver（镜像: $FNM_NODE_DIST_MIRROR）..."
  fnm install "$ver"
  fnm default "$ver"
  log "Node.js 安装完成: $(fnm exec --using="$ver" -- node --version)"
}

# ------------------------------ gvm + 最新 Go ------------------------------
install_gvm() {
  if [ ! -s "$GVM_ROOT/scripts/gvm" ]; then
    log "安装 gvm 到 $GVM_ROOT ..."
    if [ "$GVM_ROOT" = "$HOME/.gvm" ]; then
      # 默认路径，直接使用官方安装脚本
      if ! bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer"); then
        err "gvm 安装失败，请检查网络"
      fi
    else
      # 自定义路径：安装脚本固定安装到 $GVM_DEST/gvm，故传入父目录
      # （第一个位置参数是 branch，必须显式传 master）
      local dest; dest="${GVM_ROOT%/gvm}"
      [ "$dest" != "$GVM_ROOT" ] || err "自定义 GVM_ROOT 必须以 /gvm 结尾（安装脚本限制）"
      # 边界情况：dest 等于 $HOME 时安装脚本会把目录命名为 .gvm，与 $GVM_ROOT 不符
      [ "$dest" != "$HOME" ] || err "GVM_ROOT 不能是 $HOME/gvm（安装脚本会将其命名为 .gvm）"
      if ! bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer") master "$dest"; then
        err "gvm 安装失败，请检查网络"
      fi
    fi
  fi
  export GVM_ROOT
  safe_source "$GVM_ROOT/scripts/gvm" || err "gvm 加载失败"
  log "gvm 就绪"
}

install_latest_go() {
  export GO_BINARY_BASE_URL
  local ver
  ver="$(latest_go)"
  log "安装 Go $ver（镜像: $GO_BINARY_BASE_URL）..."
  # -B: 只从二进制安装（默认会 git clone 源码并完整编译，耗时极长）
  gvm install "$ver" -B
  gvm use "$ver" --default
  log "Go 安装完成: $("$GVM_ROOT/gos/$ver/bin/go" version)"
}

# ------------------------------ pyenv + 最新 Python ------------------------------
install_pyenv() {
  if [ ! -s "$PYENV_ROOT/bin/pyenv" ]; then
    log "安装 pyenv 到 $PYENV_ROOT ..."
    export PYENV_ROOT
    if ! curl -fsSL --retry 3 "https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer" | bash; then
      err "pyenv 安装失败，请检查网络"
    fi
  fi
  export PATH="$PYENV_ROOT/bin:$PATH"
  safe_eval "$(pyenv init - bash)" || true
  pyenv --version >/dev/null 2>&1 || err "pyenv 不可用"
  log "pyenv 就绪: $(pyenv --version)"
}

install_latest_python() {
  export PYTHON_BUILD_MIRROR_URL PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM
  local ver
  ver="$(latest_python)"
  log "安装 Python $ver（镜像: $PYTHON_BUILD_MIRROR_URL）..."
  pyenv install "$ver"
  pyenv global "$ver"
  log "Python 安装完成: $("$PYENV_ROOT/versions/$ver/bin/python" --version)"
}

# ------------------------------ bashrc 集成 ------------------------------
write_rc() {
  local marker="# >>> wsl-command-init >>>"
  # 清理 gvm 安装脚本追加在块外的重复 source 行（gvm 被 source 两次会让
  # cd hook 被二次包装，终端一打开就因无限递归崩溃退出）。
  # 只删“绝对路径/引号形式”的行，保留块内使用 $GVM_ROOT 变量的行。
  if [ -f "$RC_FILE" ]; then
    grep -v '\[\[ -s ".*\.gvm/scripts/gvm" \]\] && source ".*\.gvm/scripts/gvm"' "$RC_FILE" > "$RC_FILE.tmp" \
      && mv "$RC_FILE.tmp" "$RC_FILE"
  fi
  if grep -qF "$marker" "$RC_FILE" 2>/dev/null; then
    log "$RC_FILE 已包含初始化块，跳过写入"
    return 0
  fi
  mkdir -p "$(dirname "$RC_FILE")"
  cat >> "$RC_FILE" <<'EOF'

# >>> wsl-command-init >>>
# --- sdkman ---
export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# --- pyenv ---
export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"

# --- gvm（必须在 fnm 之前加载：两者都 hook cd）---
export GVM_ROOT="${GVM_ROOT:-$HOME/.gvm}"
[[ -s "$GVM_ROOT/scripts/gvm" ]] && source "$GVM_ROOT/scripts/gvm"

# --- fnm ---
export FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
export PATH="$FNM_DIR:$PATH"
export FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-__FNM_NODE_DIST_MIRROR__}"
eval "$(fnm env --use-on-cd --shell bash)"
# <<< wsl-command-init <<<
EOF
  # 把上面占位符替换为本次安装实际选中的镜像（若未安装 node，默认官方 nodejs.org）
  sed -i "s|__FNM_NODE_DIST_MIRROR__|${FNM_NODE_DIST_MIRROR:-https://nodejs.org/dist}|" "$RC_FILE"
  log "已写入 $RC_FILE（重新打开终端或执行 source $RC_FILE 生效）"
}

# ------------------------------ 只打印版本 ------------------------------
print_versions() {
  if [ "$DO_JAVA" = 1 ]; then
    if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
      safe_source "$SDKMAN_DIR/bin/sdkman-init.sh" || { printf '%-8s %s\n' "java" "sdkman 初始化失败"; return 1; }
      printf '%-8s %s\n' "java" "$(latest_oracle_java)"
    else
      printf '%-8s %s\n' "java" "sdkman 未安装，跳过"
    fi
  fi
  if [ "$DO_NODE" = 1 ]; then
    if [ -x "$FNM_DIR/fnm" ]; then
      export PATH="$FNM_DIR:$PATH" FNM_NODE_DIST_MIRROR
      pick_node_mirror
      printf '%-8s %s\n' "node" "$(latest_node)"
    else
      printf '%-8s %s\n' "node" "fnm 未安装，跳过"
    fi
  fi
  if [ "$DO_GO" = 1 ]; then
    if [ -s "$GVM_ROOT/scripts/gvm" ]; then
      export GO_BINARY_BASE_URL
      printf '%-8s %s\n' "go" "$(latest_go)"
    else
      printf '%-8s %s\n' "go" "gvm 未安装，跳过"
    fi
  fi
  if [ "$DO_PYTHON" = 1 ]; then
    if [ -s "$PYENV_ROOT/bin/pyenv" ]; then
      export PATH="$PYENV_ROOT/bin:$PATH" PYTHON_BUILD_MIRROR_URL PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM
      printf '%-8s %s\n' "python" "$(latest_python)"
    else
      printf '%-8s %s\n' "python" "pyenv 未安装，跳过"
    fi
  fi
}

# ------------------------------ 主流程 ------------------------------
main() {
  if [ "$PRINT_ONLY" = 1 ]; then
    print_versions
    return 0
  fi
  [ "$DO_APT" = 1 ] && install_system_deps
  [ "$DO_JAVA" = 1 ]   && { install_sdkman;      install_latest_java; }
  [ "$DO_NODE" = 1 ]   && { install_fnm;         install_latest_node; }
  [ "$DO_GO" = 1 ]     && { install_gvm;         install_latest_go; }
  [ "$DO_PYTHON" = 1 ] && { install_pyenv;       install_latest_python; }
  [ "$DO_RC" = 1 ]     && write_rc
  log "全部完成！"
}

main "$@"
