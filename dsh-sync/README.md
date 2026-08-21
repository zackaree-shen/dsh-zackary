# DSH Sync

这里保存我所有电脑共享的 DSH 配置、插件清单和自写插件。仓库里的 `dsh/` 目录基本镜像 `~/.dsh`（Windows 下是 `%USERPROFILE%\.dsh`）中**可共享**的部分。

## 目录结构

```text
dsh-sync/
├── dsh/
│   ├── settings.yaml                 # 全局可共享设置（不含密钥）
│   ├── .agent-presets/liangshen/     # 自用 Agent preset（梁神模式）
│   ├── profiles/
│   │   ├── desktop/                  # DSH Desktop 使用的 profile
│   │   ├── web/
│   │   ├── tui/
│   │   ├── dsh-tui/
│   │   └── lark/
│   └── plugins/
│       └── dsh-account-switcher/     # 自写插件源码
├── install.ps1                       # Windows / PowerShell 一键同步到本机
├── install.sh                        # macOS / Linux 一键同步到本机
├── export.ps1                        # 把本机改动回收到仓库（可选）
└── README.md
```

## 包含 / 不包含

包含：

- 全局 `settings.yaml`（偏好、模型默认值、市场源开关等）
- 所有 profile 的 `package.json`、`pnpm-workspace.yaml`、`cordis.yml`、`cordis.patch.yml`、`pnpm-lock.yaml`
- 自写插件 `dsh-account-switcher` 的源码
- 自用 Agent preset

不包含（每台电脑各自保留）：

- `.credentials.yaml`、`storages/account-switcher.json` 等含密钥/账号档案的文件
- `sessions/`、`attachments/`、`cache/`、`logs/`
- `node_modules/`
- AppData 里的 Electron 浏览器缓存、Cookies、Session Storage、日志、安装包

## 新电脑初始化

```bash
# 1. 克隆仓库并切到 dev 分支
git clone git@github.com:zackaree-shen/dsh-zackary.git
cd dsh-zackary
git checkout dev

# 2. 同步配置（Windows PowerShell）
cd dsh-sync
./install.ps1

# 或 macOS / Linux
cd dsh-sync
./install.sh
```

脚本会：

1. 把 `dsh/` 里的可共享文件复制到 `$DSH_HOME`（默认 `~/.dsh`）
2. 在 `profiles/desktop`、`web`、`tui`、`dsh-tui`、`lark` 下逐个执行 `pnpm install`
3. 保持本机已有的 `sessions/`、`storages/`、`.credentials.yaml` 不被删除

之后启动 DSH Desktop 即可使用同步好的插件和配置。

## 日常更新

```bash
git pull
cd dsh-sync
./install.ps1        # Windows
# 或 ./install.sh
```

## 在本机改完配置/插件后，同步回仓库

```bash
cd dsh-sync
./export.ps1         # Windows；会把本机可共享配置回收进 dsh-sync/dsh
# 然后提交推送
cd ..
git add dsh-sync
git commit -m "chore(dsh-sync): update desktop config/plugins"
git push origin dev
```

> 注意：`export.ps1` 只会回收可共享文件，不会读取/提交 `.credentials.yaml`、账号档案、会话或缓存。请提交前 `git status` 再检查一次。

## 前置条件

- Node.js + pnpm 已安装
- 使用 GitHub 托管插件时，各电脑最好配置好 GitHub SSH key（现有 lockfile 中的 `git+ssh://` 依赖需要 SSH）
- 同步前建议先退出 DSH Desktop，避免文件被占用或热加载冲突
