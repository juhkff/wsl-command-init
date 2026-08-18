# wsl-command-init

新 WSL 环境一键初始化脚本：安装常用版本管理器，并自动安装各语言当前最新版本。

## 功能

| 工具                                              | 安装的最新版本                                                           | 国内镜像                                                                                                                                                                                       |
| ------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [sdkman](https://sdkman.io)                       | 最新 **Oracle** Java（Vendor=Oracle 的最新 Release，如 `26.0.2-oracle`） | 国内暂无公共 sdkman API 镜像，默认官方（实测可用）                                                                                                                                             |
| [fnm](https://github.com/Schniz/fnm)              | 最新 Node.js（如 `v26.7.0`）                                             | 华为云 `https://mirrors.huaweicloud.com/nodejs/`（npmmirror / nodejs.org 在部分网络下对 fnm 不可用）                                                                                           |
| [gvm](https://github.com/moovweb/gvm)             | 最新 Go（如 `go1.26.5`）                                                 | `https://golang.google.cn/dl`（Google 官方国内镜像）                                                                                                                                           |
| [pyenv](https://github.com/pyenv/pyenv-installer) | 最新稳定 Python 3.x（如 `3.14.7`）                                       | npmmirror `https://registry.npmmirror.com/-/binary/python`（新版 python-build 的 `PYTHON_BUILD_MIRROR_URL` 需配合 `PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1` 使用路径替换模式，校验和仍会验证） |

安装完成后会向 `~/.bashrc` 写入集成配置（幂等，重复执行不会重复追加），并设置各语言为默认版本（`sdk` 默认 / `fnm default` / `gvm use --default` / `pyenv global`）。

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
bash setup.sh --print-versions# 只查看当前可安装的最新版本，不安装
bash setup.sh --no-apt        # 跳过系统依赖安装
bash setup.sh --no-rc         # 不写 ~/.bashrc
bash setup.sh --help          # 帮助
```

## 隔离测试（不影响现有环境）

脚本所有路径均基于 `$HOME`（或用环境变量覆盖），可在临时 HOME 中完整测试：

```bash
mkdir -p /tmp/wsl-test-home
HOME=/tmp/wsl-test-home bash setup.sh --no-apt
# 或逐个覆盖：
# SDKMAN_DIR=/tmp/x/.sdkman FNM_DIR=/tmp/x/fnm GVM_ROOT=/tmp/x/gvm \
# PYENV_ROOT=/tmp/x/.pyenv RC_FILE=/tmp/x/.bashrc bash setup.sh
```

## 镜像与目录可配置项

以下环境变量均可覆盖脚本默认值：

| 变量                                                             | 默认值                                           | 说明                                               |
| ---------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------- |
| `SDKMAN_CANDIDATES_API`                                          | `https://api.sdkman.io/2`                        | sdkman API 地址                                    |
| `FNM_NODE_DIST_MIRROR`                                           | `https://mirrors.huaweicloud.com/nodejs/`        | Node.js 下载镜像                                   |
| `GO_BINARY_BASE_URL`                                             | `https://golang.google.cn/dl`                    | Go 二进制下载镜像                                  |
| `GO_VERSION_URL`                                                 | `https://golang.google.cn/VERSION?m=text`        | Go 最新版本号来源                                  |
| `PYTHON_BUILD_MIRROR_URL`                                        | `https://registry.npmmirror.com/-/binary/python` | Python 源码下载镜像（按版本路径格式）              |
| `PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM`                          | `1`                                              | 使用路径替换镜像模式（配合上项；校验和验证仍进行） |
| `SDKMAN_DIR` / `FNM_DIR` / `GVM_ROOT` / `PYENV_ROOT` / `RC_FILE` | `$HOME` 下默认路径                               | 安装目录与 rc 文件                                 |

> 注意：gvm 官方安装脚本固定将 gvm 安装到 `$HOME/.gvm`（自定义 `GVM_ROOT` 时路径必须以 `/gvm` 结尾）。

## 注意事项

- 系统依赖步骤需要 `sudo`（WSL 默认用户可用）；`--no-apt` 跳过。
- Java / Go 安装包较大（约 150–200MB），首次安装耗时取决于网络。
- Python 为源码编译安装（pyenv 标准行为），需数分钟。
- 写入的 `~/.bashrc` 块自带防重入守卫：在同一交互 shell 内重复 `source ~/.bashrc` 会安全跳过，避免 gvm / fnm 的 `cd` hook 被二次包装导致无限递归、终端段错误退出（139）。
