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
│   ├── .agent-presets/liangshen/     # 自用 Agent preset
│   ├── profiles/                     # desktop / web / tui / dsh-tui / lark
│   └── plugins/dsh-account-switcher/ # 自写插件源码
├── install.ps1 / install.sh          # 新电脑/更新后安装
├── export.ps1 / export.sh            # 本机改动回收回仓库
└── README.md
```

`dsh/` 目录镜像 `~/.dsh`（或 `$DSH_HOME`）中可共享的部分。

## 安全边界

以下内容**绝不**进入 Git：

- `.credentials.yaml`、`storages/account-switcher.json`：含 API Key / 账号档案
- `sessions/`、`attachments/`、`cache/`、`logs/`
- `node_modules/`、`lib/`（除非是插件源码目录，如 `plugins/dsh-account-switcher/lib/client.js`）
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

1. 把 `dsh/` 下可共享文件复制到 `$DSH_HOME`（默认 `~/.dsh`）
2. 保留本机已有的 `sessions/`、`storages/`、`.credentials.yaml`
3. 对每个 profile 执行 `pnpm install --no-frozen-lockfile`
4. 自写插件以 `link:../../plugins/dsh-account-switcher` 方式被 desktop profile 引用

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

`export` 脚本只会回收可共享文件，并自动把 desktop profile 里的绝对本地路径规范化为相对路径：

- `link:C:/Users/Administrator/dsh-plugins/dsh-account-switcher`
- 规范化为 `link:../../plugins/dsh-account-switcher`

## 自写插件维护

插件源码位于 `dsh-sync/dsh/plugins/dsh-account-switcher/`。

修改后在本地验证：

```bash
cd dsh-sync/dsh/plugins/dsh-account-switcher
node smoke.mjs
```

注意：`smoke.mjs` 使用 `new URL('./index.js', import.meta.url)`，不要改回机器特定的绝对路径。

## 校验清单

- [ ] `git status` 中没有 `.credentials.yaml`、`sessions/`、`storages/`、`node_modules/`
- [ ] desktop `package.json` / `pnpm-lock.yaml` 中 `dsh-account-switcher` 使用 `link:../../plugins/dsh-account-switcher`
- [ ] `git diff --cached --check` 无空白错误
- [ ] 所有 profile 的 `package.json`、`pnpm-workspace.yaml`、`cordis.patch.yml`、`pnpm-lock.yaml` 均已同步
- [ ] 推送后远端 `origin/dev` 与本地一致
