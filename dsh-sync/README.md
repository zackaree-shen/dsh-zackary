# DSH Sync

这里保存我所有电脑共享的 DSH 配置、插件清单和自写插件。仓库里的 `dsh/` 目录基本镜像 `~/.dsh`（Windows 下是 `%USERPROFILE%\.dsh`）中**可共享**的部分。

## 目录结构

```text
dsh-sync/
├── dsh/
│   ├── settings.yaml                 # 全局可共享设置（不含密钥）
│   ├── skin-center-active.json       # 皮肤中心当前启用皮肤
│   ├── .agent-presets/liangshen/     # 自用 Agent preset（梁神模式）
│   ├── profiles/
│   │   ├── desktop/                  # DSH Desktop 使用的 profile
│   │   ├── web/
│   │   ├── tui/
│   │   ├── dsh-tui/
│   │   └── lark/
│   └── plugins/
│       └── dsh-realtime-sync/        # 自写插件源码（实时会话同步）
├── install.ps1                       # Windows / PowerShell 一键同步到本机
├── install.sh                        # macOS / Linux 一键同步到本机
├── export.ps1                        # 把本机改动回收到仓库（可选）
└── README.md

.agents/skills/dsh-sync/SKILL.md      # dsh-sync 技能（仓库根，随仓库分发）
```

## 包含 / 不包含

包含：

- 全局 `settings.yaml`（偏好、模型默认值、市场源开关等）
- 皮肤中心当前启用皮肤 `skin-center-active.json`
- 所有 profile 的 `package.json`、`pnpm-workspace.yaml`、`cordis.yml`、`cordis.patch.yml`、`pnpm-lock.yaml`
- 自写插件源码（`dsh/plugins/<name>/`，自动发现本机 `~/.dsh/plugins`、`~/dsh-plugins` 以及 profile `package.json` 里 `file:`/`link:` 引用的插件目录；`$excludedPlugins` 黑名单内的插件不会被回收）
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
2. 清空 DSH Desktop「恢复页面」残留的插件禁用状态（`plugin-management/state.json` 里的 `disabledBundles`），避免之前手动禁用过的插件在同步后仍然不加载；只处理本机存在的 profile
3. 把 `dsh-sync` 技能安装到用户级技能目录 `~/.agents/skills/`（所有 DSH 端共享，重启后即可被加载）
4. 安装 `pre-commit` git hook（`dsh-sync/hooks/pre-commit` → 仓库 `.git/hooks/`）：之后每次 `git commit` 自动把本机技能改动同步回仓库，改完技能不用再手动跑 export
5. 在 `profiles/desktop`、`web`、`tui`、`dsh-tui`、`lark` 下逐个执行 `pnpm install`（先装各插件目录自身的依赖，再装 profile）
6. 保持本机已有的 `sessions/`、`storages/`、`.credentials.yaml` 不被删除

之后启动 DSH Desktop 即可使用同步好的插件和配置。

## dsh-sync 技能

仓库根的 `.agents/skills/dsh-sync/SKILL.md` 是本套同步流程的**技能文档**（DSH 可加载的技能格式）。`install` 脚本会把它装到 `~/.agents/skills/dsh-sync/`，让所有电脑的 DSH 都能在对话中自动使用「dsh-sync」技能来指导同步操作。

- 修改技能：直接编辑 `~/.agents/skills/dsh-sync/SKILL.md`（本机）；下次 `git commit` 时 pre-commit hook 会自动把它同步回仓库并随提交推送，无需手动跑 export
- 分发技能：其他电脑 `git pull` 后 `./install.ps1` 即装好（技能 + pre-commit hook 一起装）
- 技能文件很小（纯 Markdown），永远不包含密钥/会话数据

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
./export.sh          # macOS / Linux
# 然后提交推送
cd ..
git add dsh-sync
git commit -m "chore(dsh-sync): update desktop config/plugins"
git push origin dev
```

`export` 脚本会自动发现本机所有自写插件（扫描 `~/.dsh/plugins`、`~/dsh-plugins` 以及 profile `package.json` 里的 `file:`/`link:` 依赖；`$excludedPlugins` 黑名单内的插件不会回收），并回收 `settings.yaml`、`skin-center-active.json`、各 profile 清单，把机器相关的绝对路径规范化为 `link:../../plugins/<name>` 相对形式。仓库里已存在但本机没有的 profile / 插件会被保留（可能来自另一台电脑）。

> 注意：`export.ps1` 只会回收可共享文件，不会读取/提交 `.credentials.yaml`、账号档案、会话或缓存。请提交前 `git status` 再检查一次。

## 前置条件

- Node.js + pnpm 已安装
- 使用 GitHub 托管插件时，各电脑最好配置好 GitHub SSH key（现有 lockfile 中的 `git+ssh://` 依赖需要 SSH）
- 同步前建议先退出 DSH Desktop，避免文件被占用或热加载冲突
