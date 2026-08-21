# dsh-account-switcher

cc-switch 风格的多账号管理插件：在 DSH 里管理多个 DeepSeek API Key / 模型档案，一键切换（热加载免重启）。

## 功能

- **多账号管理**：在「设置 → 插件 → 插件配置 → 账号管理」卡片里添加/编辑/删除账号档案（名称、API Key、默认模型、推理档位、可选 baseURL）
- **一键切换**：点「切换」即把该账号的 key 写入 DSH 原生凭据 `~/.dsh/.credentials.yaml`（`DEEPSEEK_API_KEY`），并更新 `~/.dsh/settings.yaml` 的 `agent-default-model`（默认模型 / 推理档位）与可选 `llm-deepseek.baseURL`
- **热加载免重启**：DSH 每请求解析凭据、settings 热加载 —— 切换后**新会话**立即生效；已存在的会话保留原路由（DSH 原生语义）
- **安全**：列表接口不回传已存 key（只返回 hasKey）；key 仅在新增/更新时提交；每次激活前自动备份凭据与 settings 文件（`*.bak-<时间戳>`）
- **手动改 key 也方便**：所有写入都是 DSH 原生明文 YAML，随时可手改 `~/.dsh/.credentials.yaml`

## 安装

```sh
dsh plugin --profile desktop add C:\Users\Administrator\dsh-plugins\dsh-account-switcher
```

重启 DSH 后，打开 设置 → 插件 → 插件配置，即可看到「账号管理」卡片。

## API（宿主侧）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/account-switcher/accounts` | 账号列表 + activeId |
| POST | `/api/account-switcher/accounts` | 新增 `{name, apiKey, model, baseURL?, reasoningEffort?}` |
| POST | `/api/account-switcher/accounts/update` | 修改 `{id, ...}`（apiKey 留空=不改） |
| POST | `/api/account-switcher/accounts/delete` | 删除 `{id}` |
| POST | `/api/account-switcher/activate` | 激活 `{id}` → 写凭据 + settings |
| GET | `/api/account-switcher/status` | 当前激活态 + 可用模型/推理档位 |

## 注意

- 切换只影响**新会话**；当前正在进行的会话继续用其已选路由
- 存储位置：`~/.dsh/storages/account-switcher.json`（账号档案，含 key，注意保管）
- 删除账号不会撤销它已写入 `.credentials.yaml` 的 key（避免误删导致当前 key 失效）
