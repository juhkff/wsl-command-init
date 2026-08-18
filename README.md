# wsl-command-init

新 WSL 环境一键初始化脚本：安装常用版本管理器，并自动安装各语言当前最新版本。

## 功能

| 工具                                              | 安装的最新版本                                                           |
| ------------------------------------------------- | ------------------------------------------------------------------------ |
| [sdkman](https://sdkman.io)                       | 最新 **Oracle** Java（Vendor=Oracle 的最新 Release，如 `26.0.2-oracle`） |
| [fnm](https://github.com/Schniz/fnm)              | 最新 Node.js（如 `v26.7.0`）                                             |
| [gvm](https://github.com/moovweb/gvm)             | 最新 Go（如 `go1.26.5`）                                                 |
| [pyenv](https://github.com/pyenv/pyenv-installer) | 最新稳定 Python 3.x（如 `3.14.7`）                                       |

安装完成后会向 `~/.bashrc` 写入各工具**官方文档**要求的集成片段（用
`# >>> wsl-command-init >>>` 标记包住，重复执行不会重复追加），并设置各语言为默认版本
（`sdk default` / `fnm default` / `gvm use --default` / `pyenv global`）。

写入的 rc 片段均与官方文档一致，不做额外发明：

```bash
# sdkman
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
# pyenv + pyenv-virtualenv 插件
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
# gvm
export GVM_ROOT="$HOME/.gvm"
[[ -s "$GVM_ROOT/scripts/gvm" ]] && source "$GVM_ROOT/scripts/gvm"
# fnm（官方默认 `fnm env`，不启用 --use-on-cd）
FNM_PATH="$HOME/.local/share/fnm"
if [ -d "$FNM_PATH" ]; then
  export PATH="$FNM_PATH:$PATH"
  eval "$(fnm env)"
fi
```

> 说明：fnm 特意不使用 `--use-on-cd`。fnm 的 `--use-on-cd` 会给 `cd()` 添加 hook，
> 而 gvm 同样 hook `cd()`，两者叠加会造成 `cd()` 被重复包装，进而在重复
> `source ~/.bashrc` 时无限递归、终端段错误退出（139）。用官方默认的 `fnm env`
> 即可正常切换 node 版本，避免该冲突。

## 一键安装（无需克隆仓库）

与 gvm 等工具的文档一样，可以直接用命令行下载并执行 `setup.sh`，无需先克隆仓库：

```bash
# gvm 文档风格：进程替换直接执行（不落盘）
bash < <(curl -s -S -L https://raw.githubusercontent.com/juhkff/wsl-command-init/main/setup.sh)

# 需要传参数时（-s 表示脚本从 stdin 读取，-- 后的参数传给脚本）：
curl -s -S -L https://raw.githubusercontent.com/juhkff/wsl-command-init/main/setup.sh | bash -s -- --no-apt
```

> 注意：`bash < <(curl ...) --参数` 这种写法会把 `--参数` 当作 bash 自身的选项，不会传给脚本；带参数请使用 `curl ... | bash -s -- ...`。

## 用法

```bash
bash setup.sh                 # 全部安装（含系统依赖 apt）
bash setup.sh --java --node   # 只安装指定项
bash setup.sh --no-apt        # 跳过系统依赖安装
bash setup.sh --no-rc         # 不写 ~/.bashrc
bash setup.sh --help          # 帮助
```

## 隔离测试（不影响现有环境）

脚本所有路径均基于 `$HOME`（或用环境变量覆盖），可在临时 HOME 中完整测试：

```bash
HOME=/tmp/wsl-test-home bash setup.sh --no-apt
# 或逐个覆盖：
# SDKMAN_DIR=/tmp/x/.sdkman FNM_DIR=/tmp/x/fnm GVM_ROOT=/tmp/x/gvm \
# PYENV_ROOT=/tmp/x/.pyenv RC_FILE=/tmp/x/.bashrc bash setup.sh
```

## 镜像与目录可配置项

默认使用官方源。国内网络可自行用以下环境变量覆盖：

| 变量                                                             | 默认值                              | 说明                   |
| ---------------------------------------------------------------- | ----------------------------------- | ---------------------- |
| `SDKMAN_CANDIDATES_API`                                          | `https://api.sdkman.io/2`           | sdkman API 地址        |
| `FNM_NODE_DIST_MIRROR`                                           | （未设置，用官方源）                | Node.js 下载镜像       |
| `GO_BINARY_BASE_URL`                                             | `https://go.dev/dl`                 | Go 二进制下载镜像      |
| `GO_VERSION_URL`                                                 | `https://go.dev/VERSION?m=text`     | Go 最新版本号来源      |
| `PYTHON_BUILD_MIRROR_URL`                                        | `https://www.python.org/ftp/python` | Python 源码下载镜像    |
| `PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM`                          | `0`                                 | 路径替换镜像时需设 `1` |
| `SDKMAN_DIR` / `FNM_DIR` / `GVM_ROOT` / `PYENV_ROOT` / `RC_FILE` | `$HOME` 下默认路径                  | 安装目录与 rc 文件     |

> 注意：gvm 官方安装脚本固定将 gvm 安装到 `$HOME/.gvm`。

## 注意事项

- 系统依赖步骤需要 `sudo`（WSL 默认用户可用）；`--no-apt` 跳过。
- Java / Go 安装包较大（约 150–200MB），首次安装耗时取决于网络。
- Python 为源码编译安装（pyenv 标准行为），需数分钟。
- rc 块写入是幂等的：已包含 `# >>> wsl-command-init >>>` 标记时不会重复追加。
