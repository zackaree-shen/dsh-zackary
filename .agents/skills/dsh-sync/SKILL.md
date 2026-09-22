---
name: dsh-sync
description: Use when syncing DSH Desktop configuration, profiles, and custom plugins across multiple computers through the dsh-zackary dev branch; covers installing on a new machine, exporting local changes back into the repo, and the safety rules for never committing secrets, sessions, caches, or node_modules.
---

# DSH 配置/插件多机同步（dsh-sync）

这个 skill 描述如何通过当前 fork 的 `dev` 分支同步 DSH Desktop 的配置、profile 和自写插件。

## 仓库布局

```text
dsh-sync/
├── dsh/
│   ├── settings.yaml                 # 全局共享设置
│   ├── skin-center-active.json       # 皮肤中心当前启用皮肤
│   ├── skins/                        # 皮肤中心用户皮肤（$DSH_HOME/skins/）
│   │   └── qq2006/                   # QQ2006 经典版（移植为 v2 user skin）
│   ├── .agent-presets/liangshen/     # 自用 Agent preset
│   ├── profiles/                     # desktop / web / tui / dsh-tui / lark
│   └── plugins/
│       ├── dsh-qq2006-chrome/        # 自写插件：qq2006 皮肤窗口装饰（条件注入）
│       └── dsh-realtime-sync/        # 自写插件源码（实时会话同步）
├── tools/                             # 独立 web 服务（不依赖 DSH Desktop）
│   ├── install-web-service.ps1/.sh    # 部署守护脚本 + 自启 + 双击入口（仅存于仓库，不部署到本机）
│   ├── register-web-task.ps1          # Windows：注册/补注册 "DSH Web Server" 计划任务（可被 UAC 兜底调用）
│   ├── dsh-web-server.ps1/.sh         # 启动并守护 `dsh web`
│   ├── dsh-web-open.ps1/.cmd/.command # 双击入口（默认浏览器网页；服务以 --no-open 启动，只开一个窗口）
│   ├── restart-dsh-web.ps1            # Windows：按正确顺序重启守护进程+服务器（改 dsh-web-server.ps1 后必须用它）
│   ├── dsh-web.ico                    # 唯一的快捷方式图标源（Windows 直接用 .ico；macOS 安装时转 .icns 装进 DSH Web.app）
│   └── new-icon.ps1                   # 重新生成 dsh-web.ico（仅存于仓库；改 artwork 时才用）
├── hooks/
│   ├── pre-commit                    # bash 版技能同步 hook（POSIX / git for Windows）
│   └── pre-commit.ps1                # PowerShell 版（无 bash 时可用，也可手工跑）
├── install.ps1 / install.sh          # 新电脑/更新后安装
├── export.ps1 / export.sh            # 本机改动回收回仓库
└── README.md
```

`dsh/` 目录镜像 `~/.dsh`（或 `$DSH_HOME`）中可共享的部分。

## 安全边界

以下内容**绝不**进入 Git：

- `.credentials.yaml`、`storages/account-switcher.json`：含 API Key / 账号档案
- `sessions/`、`attachments/`、`cache/`、`logs/`
- `node_modules/`、`lib/`（除非是插件源码目录，如 `plugins/dsh-realtime-sync/lib/index.js`）
- AppData 下的 Electron 缓存、Cookies、Session Storage、安装包

提交前必须执行：

```bash
git status --short
git diff --cached --check
grep -RInE "sk-[A-Za-z0-9]|AKIA|api[_-]?key\s*[:=]" dsh-sync/dsh --include='*.yaml' --include='*.yml' --include='*.json' --include='*.js' --include='*.mjs' || true
```

## 在新电脑安装

```bash
git clone git@github.com:zackaree-shen/dsh-zackary.git
cd dsh-zackary
git checkout dev

cd dsh-sync
./install.ps1       # Windows
# 或 ./install.sh   # macOS / Linux
```

脚本行为：

1. 把 `dsh/` 下可共享文件（含 `skin-center-active.json`、`skins/` 用户皮肤）复制到 `$DSH_HOME`（默认 `~/.dsh`）
2. 清空 DSH Desktop「恢复页面」残留的插件禁用状态（AppData `plugin-management/state.json` 的 `disabledBundles`），只处理本机存在的 profile——防止之前手动禁用过的插件在同步后不加载
3. 把 `dsh-sync` 技能装到 `~/.agents/skills/dsh-sync/`（供所有 DSH 端加载）
4. 安装 `pre-commit` hook：先用 `git rev-parse --git-path hooks` 解析 git **真正读取**的 hooks 目录，再装 bash 版 `pre-commit`（仅当该名字空闲，绝不覆盖 lefthook shim）+ PowerShell 版 `dsh-sync-pre-commit.ps1`（总是装，可手工跑）
5. 先对每个插件目录执行 `pnpm install`（插件第三方依赖如 `yaml`/`@deepseek-ai/schemastery` 必须装在插件目录内，DSH 按真实路径加载插件入口）
6. 对每个 profile 执行 `pnpm install --no-frozen-lockfile`
7. 保留本机已有的 `sessions/`、`storages/`、`.credentials.yaml`
8. 确保全局 `dsh` CLI 存在，并把 `$DSH_HOME/profiles/node_modules` 指向该 CLI 的依赖树（见下）
9. 部署独立 web 服务：登录自启 + 守护 + 双击入口

## 独立 Web 服务（`dsh web`，不依赖 DSH Desktop）

`tools/` 提供跨平台方案，`install` 会自动部署：

| | Windows | macOS |
|---|---|---|
| 自启/守护 | 计划任务 `DSH Web Server`（登录启动，失败每分钟重试） | LaunchAgent `com.dsh.web-server`（RunAtLoad + KeepAlive） |
| 双击入口 | 桌面 `DSH Web` 快捷方式 | `~/Applications/DSH Web.app`（真 app bundle：带 .icns 图标 + 注册到 LaunchServices，Launchpad/Spotlight 可见、可拖 Dock） |
| 工具/日志 | `%LOCALAPPDATA%\dsh-web\` | `~/.local/share/dsh-web/` |
| 端口 | `-Port`（默认 43120） | `DSH_WEB_PORT`（默认 43120） |

Windows 上计划任务的登录触发器固定为**当前用户**（任务以该用户的交互令牌运行，任何用户触发没有意义），普通权限即可注册；若策略仍拒绝（0x80070005），`install-web-service.ps1` 会弹一次 UAC 用提权子进程只注册任务，其余步骤不提权。另外 `pnpm` 缺失时依赖安装被跳过并警告，但 web 服务仍会照常部署。

排查：

```powershell
Start-ScheduledTask -TaskName 'DSH Web Server'
Get-Content "$env:LOCALAPPDATA\dsh-web\server.log" -Tail 20
```

改了 `dsh-web-server.ps1`（或换了全局 CLI 版本）之后**必须整体重启**，不能只重启服务器：正在跑的守护进程已经把旧脚本读进内存，杀掉服务器后它会用**旧参数**把它拉起来。用 `restart-dsh-web.ps1`（部署在 tools 目录），它按正确顺序停掉计划任务运行器 → 守护进程 → 服务器，再重新拉起。注意它会关掉你正在用的 Web UI，之后用 `dsh-web-open.cmd` 或桌面快捷方式重开。

```bash
launchctl kickstart -k "gui/$(id -u)/com.dsh.web-server"
tail -20 ~/.local/share/dsh-web/server.log
```

六个必须知道的坑：

- **运行时的后端是全局安装的 `dsh`，不是本仓库的 `packages/`。** `dsh-web-server.ps1` 固定用 `%APPDATA%\npm\dsh.cmd` 启动（脚本注释即"boots the profile with the globally installed `dsh` CLI"），而 `$DSH_HOME/profiles/node_modules/@deepseek-ai/*` 全是指向该全局依赖树（`npm\node_modules\@deepseek-ai\dsh\node_modules\...`）的 junction——没有任何一条指向 `dsh-zackary`。所以浏览器版和 DSH Desktop 用的是同一份后端实现。两条推论：
  - 后端插件**源码**的改动（`packages/**`）不会自动生效，要生效必须让全局 CLI 重装/升级，或改成从源码起服务。
  - 只有**配置**类改动（`settings.yaml`、profile 清单）才走这套同步：`settings` 是每次请求重读快照的，改完连重启都不需要。
- **别只看前端是浏览器还是 Desktop 就判断跑的是哪份 dsh**（两者后端相同，但顺序、加载路径、生效条件完全不同）。核实命令：

  ```powershell
  # 谁占着端口、命令行是什么
  $pid_ = (Get-NetTCPConnection -LocalPort 43120 -State Listen).OwningProcess
  (Get-CimInstance Win32_Process -Filter "ProcessId=$pid_").CommandLine
  # profile 的 @deepseek-ai/* 指向哪
  Get-Item "$env:DSH_HOME\profiles\node_modules\@deepseek-ai\*" | Select-Object Name, Target
  ```
- `dsh web` 从 profile 目录向上解析 `@deepseek-ai/*`。DSH Desktop 提供的是指向 `app.asar` 的 junction，普通 node 读不到，所以必须让 `$DSH_HOME/profiles/node_modules` 指向全局 CLI 的依赖树（`install` 自动完成；机器本地，不参与同步）。
- 守护脚本"端口已通就退出"的分支**不能写日志**：正在运行的实例独占日志文件，第二个实例会因此崩掉，并让计划任务反复失败重试。
- **launchd/systemd 给 agent 的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`**：`dsh-web-server.sh` 曾靠 `command -v dsh` 找 CLI，agent 被重载/重启后就刷 "dsh not found on PATH"（10 秒一次）；且 `dsh` 的 `#!/usr/bin/env node` 同样需要 PATH 里有 node（本机 node 在版本化的 `~/.local/lib/nodejs/node-v<ver>/bin`，由 `~/.zshrc` 注入，launchd 看不见）。现已双保险：supervisor 显式解析 dsh/node 绝对路径（PATH → 标准位置 → nodejs tarball glob，运行时扫所以换 node 版本自动跟随），`install-web-service.sh` 生成 plist/systemd unit 时固化安装时的 PATH（重跑 install 刷新）。
- **0.1.5+ 的 `dsh web` 有启动期 token 认证**：裸地址返回 401 "authentication required"，必须打开服务每次启动打印的 `?token=...` URL（token 随重启更换）。双击入口会从 `server.log` 取 token，从新到旧逐个探测（非 401 即存活）再打开，避免重启竞态时打开失效 token；手工排查时取 `server.log` 里最后一条 `dsh web: http://.../?token=...`。
- **全局 CLI 版本漂移会让 profile 插件在启动时崩溃。** profile 插件 lockfile 是针对 `install.ps1` 锁定的 `DshVersion`（当前 `0.1.5-rc.2`）解析的；CLI 升到更高版本后，`dsh web` 会在加载约 150 秒后以 `SyntaxError: does not provide an export named ...` 崩溃并循环重启——崩溃前端口已在监听，看起来像"服务活着"。恢复：`npm i -g @deepseek-ai/dsh@<DshVersion>` 退回锁定值。2026-09 实例：0.1.5-rc.2 删除了 `installSettingsSection`，`@linxin666/dsh-client-ui-skin-center@0.2.9` 即崩；该组合最初由把 web profile 迁到 `@linxin666/dsh-web-all@0.3.19`（不再引用该导出）解决，此后随插件线推进到 `0.3.23`（当前 profile 锁定值）；0.1.5-rc.2 配该 profile 已实测启动后持续存活。要升 CLI，先把 `DshVersion` 和 profile 插件 lockfile 一起升。

## 更新已有电脑

```bash
git pull
cd dsh-sync
./install.ps1       # 或 ./install.sh
```

## 把本机改动同步回仓库

```bash
cd dsh-sync
./export.ps1        # Windows
# 或 ./export.sh    # macOS / Linux

cd ..
git add dsh-sync
git commit -m "chore(dsh-sync): update desktop config/plugins"
git push origin dev
```

**先 `install` 再 `export`。** `export` 会把本机副本（技能、profile 清单与 lockfile）回写仓库，因此本机落后于仓库时它会把这些文件回滚：另一台电脑推了技能/配置更新、本机还没来得及 `install` 的情况下直接 `export`，仓库里那份更新就被本机旧副本覆盖。回收前先跑一次 `./install.ps1`（它按仓库内容更新本机），再 `export`。

**技能改动的同步**：`install` 会尝试装好 `pre-commit` git hook（bash 版源码 `dsh-sync/hooks/pre-commit`，PowerShell 版 `hooks/pre-commit.ps1`），它能把本机 `~/.agents/skills/dsh-sync/SKILL.md` 与仓库副本比对，有差异就复制回仓库并暂存。约定：已安装技能的本机以 `~/.agents/skills/dsh-sync/SKILL.md` 为准，不要直接编辑仓库里的副本。**但在 lefthook 管理的 worktree 上 hook 装不进去（见下），所以默认按"手工回收"操作。**

> **hook 曾经静默失效过（2026-09 已修），但布局仍然脆弱，提交后请核对一次。** 历史上它有两个坑：
>
> 1. **`core.hooksPath` 不指向 `.git/hooks`。** 本仓库用 lefthook，`scripts/install-lefthook.mjs` 把 `core.hooksPath` 设为 `.git/dsh-hooks`。旧版 `install.ps1` 硬编码写 `.git/hooks/pre-commit`，那个文件 git 根本不会读。
> 2. **hook 是 bash 脚本**，需要真正可用的 bash + `cmp`/`cp`/`dirname`。Windows 上 `C:\Windows\system32\bash.exe` 只是 WSL 启动器（未装发行版时直接报错）。
>
> 现在 `install.ps1` / `install.sh` 的行为：
>
> - 用 `git rev-parse --git-path hooks` 解析**真实** hooks 目录（自动跟随 `core.hooksPath` 与 worktree），不再硬编码 `.git/hooks`
> - **绝不覆盖已存在的 `pre-commit`**：lefthook 生成的那个 shim 一旦被替换，`lefthook.yml` 里的全部 job 会静默失效
> - 无论能否抢到 `pre-commit`，都会装一份**无依赖**的 PowerShell 版 `dsh-sync-pre-commit.ps1`，可用于手工同步
> - Windows 上仅当裸 `pre-commit` 空缺时才额外写 `pre-commit.cmd`（git 优先裸名，所以它不会和 shim 打架）
>
> **本机当前状态：`pre-commit` 被 lefthook shim 占用，所以 hook 不会自动跑**——`dsh-hooks` 目录由 lefthook 全量重写，往里插链式调用会被冲掉。因此改完技能后请**默认手工回收**（见下）。
>
> 手工同步 skill（任意平台都可用，已验证）：
>
> ```powershell
> powershell -NoProfile -File .git\dsh-hooks\dsh-sync-pre-commit.ps1
> ```
>
> 有差异才输出并 `git add`，无差异静默退出 0。
>
> 每次改技能后完整回收：
>
> ```powershell
> # 以本机为准，手工回收技能 + 共享配置
> Copy-Item -LiteralPath "$HOME\.agents\skills\dsh-sync\SKILL.md" `
>           -Destination "<repo>\.agents\skills\dsh-sync\SKILL.md" -Force
> cd dsh-sync; ./export.ps1; cd ..
> git add dsh-sync .agents/skills/dsh-sync/SKILL.md
> git status --short          # 确认技能改动已 staged，没有意外文件
> ```

判断 hook 到底有没有生效：提交后跑 `git log -1 --stat`，列表里应出现 `.agents/skills/dsh-sync/SKILL.md`。没出现就是 hook 没跑，用上面的手工命令回收即可。

使用本技能时：如果会话中修改了技能文件或任何共享配置（`settings.yaml`、`skin-center-active.json`、profile、插件、preset），完成后应**自动**执行 export → commit → push，无需用户再提醒（除非用户明确要求不推送）。

`export` 脚本只会回收可共享文件（`settings.yaml`、`skin-center-active.json`、`skins/` 用户皮肤、各 profile 清单与 lockfile、Agent preset、自写插件），并自动把 profile 里的机器相关绝对路径（`file:`/`link:` 依赖与 lockfile 目录）规范化为 `link:../../plugins/<name>` 相对形式：

- `link:C:/Users/<user>/dsh-plugins/<plugin>`
- `file:C:/Users/<user>/dsh-realtime-sync`
- 统一规范化为 `link:../../plugins/<plugin-name>`

插件发现：export 会扫描 `~/.dsh/plugins`、`~/dsh-plugins` 以及各 profile `package.json` 里 `file:`/`link:` 引用的目录，自动入库；`$excludedPlugins` 黑名单（如已卸载的 `dsh-account-switcher`）不会被回收。仓库里本机没有的 profile / 插件会被保留（可能来自另一台电脑）。

## 自写插件维护

插件源码位于 `dsh-sync/dsh/plugins/<插件名>/`（如 `dsh-realtime-sync`）。

修改后在本地验证：

```bash
cd dsh-sync/dsh/plugins/dsh-realtime-sync     # 或对应插件目录
node lib/index.js 的 smoke 脚本（如存在）
```

注意：`smoke.mjs` 使用 `new URL('./index.js', import.meta.url)`，不要改回机器特定的绝对路径。

## 多模态（图片输入）模型配置

DSH 是否允许读图，**不取决于模型自身能力，而取决于 `settings.yaml` 里的型号目录是否声明了 image 输入**。声明缺省时 `llm-deepseek` 会把该型号当成纯文本（`inputModalities ?? ['text']`），于是：

- `read_image` 工具直接拒绝：`model "X" does not declare image input`（`tool-fs/src/read-image.ts` 的 `assertImageCapableRoute`）
- 用户粘贴/上传的图片在适配器层被拒：`DeepSeek model "X" does not accept image input.`（`UNSUPPORTED_CONTENT`）
- `llm-pi-ai` 路径同理，但字段名是 `input:` 而不是 `inputModalities:`

让 `deepseek-official`（`llm-deepseek` 命名空间）某个型号可读图：

```yaml
llm-deepseek:
  models:
    - id: deepseek-flash
      name: deepseek-flash
      inputModalities: [text, image]
      imagePixelBudget: 640000   # 默认 64 万像素
      imageMaxBytes: 1048576     # 默认 1 MiB
      # imageDetail: low         # 可选；low 时默认 512x512 像素预算
```

约束（`resolveModels` 会 fail loud）：

- `inputModalities` 只能含 `text` / `image`，不能为空、不能重复
- 纯文本型号**不能**声明 `imagePixelBudget` / `imageMaxBytes` / `imageDetail`
- **`models` 列表是整字段覆盖**：一旦写了 `models:`，默认目录（`deepseek-v4-flash` / `deepseek-v4-pro` / `deepseek-v4-flash-vision-exp`）就整体失效，没列出的型号变成"未登记直通"，一律按纯文本处理。所以给某个型号加 image 时，别漏掉列表里其它要保留的型号
- 配置**热生效**：适配器每次请求重新读 settings 快照，改完不需要重启 DSH

### 验证某个型号是否真的支持图片

不要靠型号名猜（`-vision-exp` 这类后缀可能与实际后端不一致）。直接打官方接口，用**不可从上下文猜出**的图（纯色块会被瞎蒙）：

```powershell
# 生成 200x200、白底黑字 "7429" 的探针图
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 200,200
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::White)
$g.DrawString('7429', (New-Object System.Drawing.Font 'Arial',72,([System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::Black, 20,55)
$g.Dispose(); $bmp.Save("$env:DSH_HOME\cache\probe.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
```

把该图以 `data:image/png;base64,...` 塞进 `content` 数组（`{type:'image_url'}`）请求 `POST https://api.deepseek.com/chat/completions`，看模型答什么：

- 答出图中内容 → 真·多模态，可以放心声明 `inputModalities: [text, image]`
- reasoning 里出现 `[Unsupported Image]` / "cannot see image" → 该路由把图丢了，**不要**声明 image，否则等于让用户把图存进会话历史却永远看不见
- 注意 `max_tokens` 要给够：思考模式下 `reasoning_content` 会把配额吃光，`content` 返回空串 + `finish_reason: length` 会被误判成失败

2026-09 实测（`https://api.deepseek.com`，同一把 key）：

| 请求的 model id | 上游 model | 读图结果 |
|---|---|---|
| `deepseek-flash` | `deepseek-flash` | ✅ 正确读出 |
| `deepseek-v4-flash` | `deepseek-flash` | ✅ 正确读出 |
| `deepseek-v4-flash-vision-exp` | `deepseek-flash` | ✅ 正确读出 |
| `deepseek-v4.1-flash-expires-on-0910` | `deepseek-flash` | ✅ 正确读出 |
| `deepseek-v4-pro` | `deepseek-v4-pro` | ❌ `[Unsupported Image]`，纯文本 |

即：除 `deepseek-v4-pro` 外都汇聚到同一个 `deepseek-flash` 多模态后端；`deepseek-flash` 本身即可读图，无需改默认型号。

### 端到端自检

配置完后在**任意 DSH 会话**里用本会话正在跑的型号调一次 `read_image`（读一张已知内容的图）。能返回图片且模型能描述出图中内容，就说明 settings→适配器→附件服务→路由闸门整条链路通。

## 校验清单

- [ ] `git status` 中没有 `.credentials.yaml`、`sessions/`、`storages/`、`node_modules/`
- [ ] profile `package.json` / `pnpm-lock.yaml` 中没有 `file:C:/Users/...` 或 `link:C:\Users\...` 机器绝对路径（应为 `link:../../plugins/<name>`）
- [ ] `git diff --cached --check` 无空白错误
- [ ] 所有 profile 的 `package.json`、`pnpm-workspace.yaml`、`cordis.patch.yml`、`pnpm-lock.yaml` 均已同步
- [ ] 若要共享的型号读图：`settings.yaml` 该型号已声明 `inputModalities: [text, image]`，且确实打过接口验证过（不是靠型号名推断）
- [ ] 推送后远端 `origin/dev` 与本地一致
