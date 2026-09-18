# DSH Sync

这里保存我所有电脑共享的 DSH 配置、插件清单和自写插件。仓库里的 `dsh/` 目录基本镜像 `~/.dsh`（Windows 下是 `%USERPROFILE%\.dsh`）中**可共享**的部分。

## 目录结构

```text
dsh-sync/
├── dsh/
│   ├── settings.yaml                 # 全局可共享设置（不含密钥）
│   ├── skin-center-active.json       # 皮肤中心当前启用皮肤
│   ├── skins/                        # 皮肤中心用户皮肤（镜像 ~/.dsh/skins/）
│   │   └── qq2006/                   # QQ2006 经典版（v2 user skin，可在皮肤中心切换）
│   ├── .agent-presets/liangshen/     # 自用 Agent preset（梁神模式）
│   ├── profiles/
│   │   ├── desktop/                  # DSH Desktop 使用的 profile
│   │   ├── web/
│   │   ├── tui/
│   │   ├── dsh-tui/
│   │   └── lark/
│   └── plugins/
│       ├── dsh-qq2006-chrome/        # 自写插件：qq2006 皮肤窗口装饰（条件注入）
│       └── dsh-realtime-sync/        # 自写插件源码（实时会话同步）
├── tools/                            # 独立 web 服务的守护/入口/安装脚本
│   ├── install-web-service.ps1       # Windows：部署工具 + 登录计划任务 + 桌面快捷方式
│   ├── install-web-service.sh        # macOS：LaunchAgent + DSH Web.app；Linux：systemd + .desktop
│   ├── register-web-task.ps1         # Windows：注册/补注册 "DSH Web Server" 计划任务（被拒时可由 UAC 兜底调用）
│   ├── dsh-web-server.ps1 / .sh      # 启动并守护 `dsh web`（幂等、崩溃自动重启）
│   └── dsh-web-open.ps1/.cmd/.command# 双击入口：确保服务在跑，再开默认浏览器网页
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
- 皮肤中心用户皮肤 `skins/`（镜像 `~/.dsh/skins/`，如自移植的 `qq2006` 经典皮肤）
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
7. 确保全局 `dsh` CLI 存在（缺失时 `npm i -g @deepseek-ai/dsh@0.1.5-rc.2`，`-DshVersion` 可覆盖），并把 `$DSH_HOME/profiles/node_modules` 指向该 CLI 的依赖树，让 `dsh web` 能脱离 DSH Desktop 独立启动
8. 部署独立 web 服务：登录自启 + 守护 + 桌面/应用入口（详见下一节）

之后即可使用：

- 想用 DSH Desktop：直接启动它（active profile 见 `profile-selection/state.json`）
- 不想装 DSH Desktop，或想双击就开：见下一节

## 独立 Web 服务（不需要 DSH Desktop）

`install` 会把 `web` profile 做成**常驻本地服务 + 双击即开的浏览器页面**：

| | Windows | macOS |
|---|---|---|
| 自启/守护 | 计划任务 `DSH Web Server`（登录启动，失败每分钟重试） | LaunchAgent `com.dsh.web-server`（RunAtLoad + KeepAlive） |
| 双击入口 | 桌面 `DSH Web` 快捷方式 | `~/Applications/DSH Web.app`（可拖到 Dock） |
| 工具目录 | `%LOCALAPPDATA%\dsh-web\tools` | `~/.local/share/dsh-web/tools` |
| 日志 | `%LOCALAPPDATA%\dsh-web\server.log` | `~/.local/share/dsh-web/server.log` |
| 端口 | 43120（`-Port` 可改） | 43120（`DSH_WEB_PORT` 可改） |

Windows 上计划任务的登录触发器固定为**当前用户**（任务本身以该用户的交互令牌运行，任何用户触发没有意义），因此普通权限的 PowerShell 就能注册；若组策略仍拒绝（0x80070005），`install-web-service.ps1` 会自动弹一次 UAC，用提权子进程只注册任务，快捷方式、boot 自检和启动仍以普通权限执行。拒绝 UAC 会让安装明确失败并给出恢复命令。

双击入口的行为：确认端口有人服务 → 没有就用守护脚本拉起（隐藏窗口）→ 在**默认浏览器**中打开网页。服务以 `--no-open` 启动，自身从不弹浏览器；打开网页只由双击入口负责，一次只开一个标签页，登录自启时不会弹任何窗口。

守护脚本的行为：端口已通就立刻 `exit 0`（**不写日志**，所以第二个实例不会失败）；服务退出后自动重启；连续 5 次秒退则放弃，并把原因留在日志里。

```powershell
# Windows：只重新注册服务 / 改端口
cd dsh-sync
./install.ps1 -SkipInstall -Port 43120
Start-ScheduledTask -TaskName 'DSH Web Server'
Get-Content "$env:LOCALAPPDATA\dsh-web\server.log" -Tail 20
```

```bash
# macOS：只重新注册服务 / 改端口
cd dsh-sync
DSH_WEB_PORT=43120 ./install.sh --skip-install
launchctl kickstart -k "gui/$(id -u)/com.dsh.web-server"
tail -f ~/.local/share/dsh-web/server.log
```

> 关键点：`dsh web` 需要 `$DSH_HOME/profiles/node_modules` 能解析 `@deepseek-ai/*`。DSH Desktop 提供的是指向 `app.asar` 的 junction，普通 node 读不了，所以 `install` 会把该目录指向全局 CLI 自己的依赖树（Windows junction / macOS symlink）；已有可用目录就不动，不可用则备份后重建。此步骤是**机器本地**的，不参与同步。

### 排障：`ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`

某台机器若设了 `minimumReleaseAge`（如 1440 分钟），而共享 lockfile 固定了刚发布的版本，`pnpm install` 会**整段失败**、web 服务随之起不来。两层防护：

1. 各 profile 的 `pnpm-workspace.yaml` 已把易变 scope 加进 `minimumReleaseAgeExclude`（`@linxin666/*`、`@lezer/*`、`@codemirror/*`）
2. `install.ps1` / `install.sh` 首次失败后自动用 `--config.minimumReleaseAge=0` 重试一次

手动修复（任选）：

```powershell
cd "$env:USERPROFILE\.dsh\profiles\web"
pnpm install --no-frozen-lockfile --config.minimumReleaseAge=0
```

```bash
cd "$HOME/.dsh/profiles/web"
pnpm install --no-frozen-lockfile --config.minimumReleaseAge=0
```

装完重启服务：`Start-ScheduledTask -TaskName 'DSH Web Server'`（Windows）或 `launchctl kickstart -k "gui/$(id -u)/com.dsh.web-server"`（macOS）。

### 排障：`the value for "version" ... must be a string`

`.credentials.yaml` 有两种布局，且**互不兼容**：

| CLI 版本 | 只认的布局 |
|---|---|
| 0.1.0-rc.x 及更早 | 扁平（顶层直接是 `KEY: value`） |
| 0.1.1-rc.2 及之后 | 版本化（`version: 1` + `refs:` 下嵌套） |

不匹配时每次启动都会 `credentials-local: the value for "version" in ... must be a string`，服务起不来、浏览器白屏。`install` 会自动处理：把全局 CLI 升到 `0.1.5-rc.2`（`-DshVersion` / `DSH_VERSION` 可覆盖），并把扁平布局迁移为版本化布局（先备份 `.credentials.yaml.bak-<时间戳>`；转换与 dsh 自己的 `renderFlatLayoutMigration()` 逐字节一致）。

### 排障：`exists and is not a symlink`

`$DSH_HOME/profiles/node_modules` 是 **dsh 自己管理**的：每次启动 `healProfilesModuleFallback()` 把它维护成"每个包一个符号链接"。任何**真实目录**混在里面都会让启动直接抛 `dsh: <path> exists and is not a symlink` 并退出。`install` 会自动把这类条目隔离到 `profiles/node_modules.real-<时间戳>/`（整个目录是链接时则移除该链接），让 dsh 重建。

### 排障：启动约两分钟后崩溃，`does not provide an export named ...`

全局 `dsh` CLI 比 profile 插件 lockfile 的解析基准（`install.ps1` 的 `DshVersion`，当前 `0.1.5-rc.2`）新。profile 插件（如 `@linxin666/*`）按锁定版本构建，新 CLI 删除或改名导出后，`dsh web` 进入崩溃-重启循环；且崩溃前端口已在监听，看起来像"页面坏了"而不是"版本不配"。恢复：退回锁定值。

```powershell
npm i -g @deepseek-ai/dsh@0.1.5-rc.2
Start-ScheduledTask -TaskName 'DSH Web Server'
```

要升 CLI，先把 `DshVersion` 和 profile 插件 lockfile 一起升（前提是插件生态有适配新版的 release）。`install` 现在会在 CLI 高于锁定值时打印警告。

2026-09 的实例与结论：`0.1.5-rc.2` 删除了 `installSettingsSection`，旧 web profile 的 `@linxin666/dsh-client-ui-skin-center@0.2.9` 因此崩溃；该 profile 迁到 `@linxin666/dsh-web-all@0.3.19` 后不再引用该导出。本机已按此升级到 `0.1.5-rc.2` 并实测启动后持续存活（空载窗口远超 150 秒崩溃点），`DshVersion` 与 web profile 的清单/lockfile 已同步提升。

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

- Node.js + npm + pnpm 已安装（`install` 会在缺少全局 `dsh` 时自动 `npm i -g`）。pnpm 不在 PATH 时，profile/插件依赖会被跳过（仅复制文件，并给出警告），web 服务不受影响、照常部署；装好 pnpm 后重跑 `install.ps1` 即可补装依赖
- macOS / Linux 下 `install.sh` 需要 `bash` 与 `curl`（macOS 自带）
- 使用 GitHub 托管插件时，各电脑最好配置好 GitHub SSH key（现有 lockfile 中的 `git+ssh://` 依赖需要 SSH）
- 同步前建议先退出 DSH Desktop，避免文件被占用或热加载冲突
