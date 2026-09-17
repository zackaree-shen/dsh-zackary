# Agent Note: dsh-sync web 服务安装健壮性

Status: implemented

[English](2026-09-11-dsh-sync-web-service-install-robustness.md) | 中文

## 问题

一次全新 Windows 机器的部署,让独立 web 服务「装不上」或「崩溃循环」的三条互相独立的路径同时现形:

1. `dsh-sync/tools/install-web-service.ps1` 过去在脚本内直接注册 "DSH Web Server" 计划任务,且 `$ErrorActionPreference = 'Stop'`。在原生 Windows 上,非提权的 PowerShell——包括管理员的 UAC 过滤令牌——可能无权写入任务计划程序根文件夹,`Register-ScheduledTask` 因此报 0x80070005,安装器在创建桌面快捷方式、boot 自检和首次启动之前就中止。
2. `install.ps1` 在 PATH 上找不到 `pnpm` 时提前 `return`,这个 `return` 同时跳过了 web 服务部署,于是命中 pnpm 警告的机器根本没有尝试注册任务。
3. 安装四天后,全局 CLI 漂移到 `@deepseek-ai/dsh@0.1.5-rc.2`,而 profile lockfile 仍锁定 `@linxin666/dsh-skins@0.2.9`(经 `@linxin666/dsh-client-ui-skin-center@0.2.9`,针对 `dsh-settings@0.1.1-rc.2` 构建)。新 CLI 删除了 `installSettingsSection` 导出,`dsh web` 加载约 150 秒后以 `SyntaxError: does not provide an export named 'installSettingsSection'` 崩溃并循环重启——每次加载窗口期内端口仍在监听,伪装成健康的服务。

## 决策

任务注册移入 `tools/register-web-task.ps1`,由 `install-web-service.ps1` 以子进程运行;辅助脚本注册成功退出 0,注册被拒退出 2,其余失败退出 1。登录触发器限定为注册用户(`$trigger.UserId`),与任务自身的交互令牌主体一致,并让非提权 shell 能通过根文件夹写入检查。退出码为 2 时,安装器经 `Start-Process -Verb RunAs` 用同一段辅助脚本重试一次,只有注册这一步被提权;快捷方式、boot 自检与启动仍使用用户令牌,拒绝 UAC 会让安装带着恢复命令明确失败。`install.ps1` 的 pnpm 缺失提前返回路径现在同样调用 `Invoke-WebServiceInstall`。

两个安装器的 CLI 锁定版本保持 `0.1.1-rc.2`,并且当 CLI 版本高于锁定值时打印警告,点名崩溃症状与精确的重装命令;这个锁定值是与 profile 插件 lockfile 的配对契约,不只是下限。事故中的恢复手段是把全局 CLI 降回锁定值——0.2.9 之上没有兼容的 `dsh-skins` 发布版,插件生态升级这条路走不通。

## 备选方案

**整个安装器提权运行。** 否决:快捷方式创建和 boot 自检无需提权却被一起提权,而且每次安装都会弹 UAC,而不是只在策略拒绝注册时。

**用「启动」文件夹快捷方式取代计划任务。** 否决:它不需要提权,但失去失败自动重启,且偏离所有机器统一文档化的部署形态,也与 macOS 的 LaunchAgent 不一致。

**经 `schtasks /Create /XML` 从任务 XML 注册。** 否决:探测表明它到达同一个任务计划程序根文件夹写入检查、同一个 0x80070005;起决定作用的是触发器范围,不是 API 面。

**强行升级插件树去适配新 CLI**(`pnpm.overrides` 指向 skin-center 0.3.23)。就本次事故而言否决:bundle 入口 `@linxin666/dsh-skins` 最高只有 0.2.9,强推更新的 skin-center 是在跟生态自己的 manifest 对抗;锁定版本仍是整套入库 lockfile 的解析基准。

## 后果

用户作用域的触发器能通过非提权写入检查,因此正常安装注册任务不再弹出任何提权提示。任务只在注册用户登录时启动服务,而这正是服务所服务的唯一账号 profile。策略仍然拒绝注册的机器只需一次 UAC 确认,且任务注册本身会持久化这次授权。将来 CLI 升到锁定值之上,会在下次安装时以警告显形,而不是以无法解释的崩溃循环显形。手工重新注册就是带着目标 `-Port` 直接运行该辅助脚本。
