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
│   ├── .agent-presets/liangshen/     # 自用 Agent preset
│   ├── profiles/                     # desktop / web / tui / dsh-tui / lark
│   └── plugins/
│       └── dsh-realtime-sync/        # 自写插件源码（实时会话同步）
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

1. 把 `dsh/` 下可共享文件（含 `skin-center-active.json`）复制到 `$DSH_HOME`（默认 `~/.dsh`）
2. 清空 DSH Desktop「恢复页面」残留的插件禁用状态（AppData `plugin-management/state.json` 的 `disabledBundles`），只处理本机存在的 profile——防止之前手动禁用过的插件在同步后不加载
3. 先对每个插件目录执行 `pnpm install`（插件第三方依赖如 `yaml`/`@deepseek-ai/schemastery` 必须装在插件目录内，DSH 按真实路径加载插件入口）
4. 对每个 profile 执行 `pnpm install --no-frozen-lockfile`
5. 保留本机已有的 `sessions/`、`storages/`、`.credentials.yaml`

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

`export` 脚本只会回收可共享文件（`settings.yaml`、`skin-center-active.json`、各 profile 清单与 lockfile、Agent preset、自写插件），并自动把 profile 里的机器相关绝对路径（`file:`/`link:` 依赖与 lockfile 目录）规范化为 `link:../../plugins/<name>` 相对形式：

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

## 校验清单

- [ ] `git status` 中没有 `.credentials.yaml`、`sessions/`、`storages/`、`node_modules/`
- [ ] profile `package.json` / `pnpm-lock.yaml` 中没有 `file:C:/Users/...` 或 `link:C:\Users\...` 机器绝对路径（应为 `link:../../plugins/<name>`）
- [ ] `git diff --cached --check` 无空白错误
- [ ] 所有 profile 的 `package.json`、`pnpm-workspace.yaml`、`cordis.patch.yml`、`pnpm-lock.yaml` 均已同步
- [ ] 推送后远端 `origin/dev` 与本地一致
