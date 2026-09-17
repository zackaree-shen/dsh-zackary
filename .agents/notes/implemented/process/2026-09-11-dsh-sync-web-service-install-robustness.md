# Agent Note: dsh-sync web service install robustness

Status: implemented

English | [中文](2026-09-11-dsh-sync-web-service-install-robustness.zh.md)

## Problem

A single deployment to a fresh Windows machine surfaced three independent ways for the standalone web service to end up absent or crash-looping:

1. `dsh-sync/tools/install-web-service.ps1` registered the "DSH Web Server" scheduled task inline with `$ErrorActionPreference = 'Stop'`. On stock Windows, a non-elevated PowerShell — including an administrator's UAC filtered token — may not write to the Task Scheduler root folder, so `Register-ScheduledTask` fails with 0x80070005 and the installer aborts before the Desktop shortcut, the boot check, and the first start.
2. `install.ps1` returns early when `pnpm` is missing from PATH, and that return also skipped the web-service deployment, so a machine that hit the pnpm warning never attempted the task at all.
3. Four days after the install, the global CLI drifted to `@deepseek-ai/dsh@0.1.5-rc.2` while the profile lockfile still pinned `@linxin666/dsh-skins@0.2.9` (via `@linxin666/dsh-client-ui-skin-center@0.2.9`, built against `dsh-settings@0.1.1-rc.2`). The newer CLI dropped the `installSettingsSection` export, so `dsh web` loaded for about 150 seconds, crashed with `SyntaxError: does not provide an export named 'installSettingsSection'`, and restart-looped — with the port listening during each load window, which masqueraded as a healthy server.

## Decision

Task registration lives in `tools/register-web-task.ps1`, which `install-web-service.ps1` runs as a child process; the helper exits 0 on registration, 2 when registration is denied, and 1 on any other failure. The logon trigger is scoped to the registering user (`$trigger.UserId`), which matches the task's interactive-token principal and lets a non-elevated shell pass the root-folder write check. On exit code 2 the installer reruns the same helper once through `Start-Process -Verb RunAs`, so only the registration is elevated; the shortcut, the boot check, and the start keep the user's token, and a declined UAC prompt fails the install with the recovery command. `install.ps1` now calls `Invoke-WebServiceInstall` on the pnpm-missing early-return path as well.

The CLI pin stays at `0.1.1-rc.2` in both installers, and a CLI rank above the pin now prints a warning naming the boot-crash symptom and the exact reinstall command; the pin is a pairing contract with the profile plugin lockfile, not merely a minimum. During the incident, recovery was downgrading the global CLI back to the pin — no compatible `dsh-skins` release exists above 0.2.9, so the plugin-ecosystem upgrade path was not available.

## Alternatives considered

**Elevate the entire installer.** Rejected: it would elevate shortcut creation and the boot check for no benefit, and it would show a UAC prompt on every install instead of only when a policy denies registration.

**Replace the scheduled task with a Startup-folder shortcut.** Rejected: it needs no elevation, but it loses restart-on-failure and diverges from the deployment shape documented for every machine and from the macOS LaunchAgent.

**Register from task XML via `schtasks /Create /XML`.** Rejected: probing reached the same Task Scheduler root-folder write check and the same 0x80070005; the discriminating factor is the trigger scope, not the API surface.

**Force-upgrade the plugin tree against the newer CLI** (`pnpm.overrides` for skin-center 0.3.23). Rejected for the incident: the bundle entry `@linxin666/dsh-skins` tops out at 0.2.9, so forcing a newer skin-center fights the ecosystem's own manifest; the pin remains the version the whole checked-in lockfile was resolved against.

## Consequences

A normal install registers the task without any elevation prompt, because the user-scoped trigger passes the non-elevated write check. The task starts the server only at the registering user's logon, which is the only account whose profile the server serves. A machine whose policy still denies registration costs exactly one UAC consent, persisted by the task registration itself. A future CLI upgrade above the pin is visible as a warning at the next install instead of as an unexplained crash loop. Re-registering by hand is running the helper directly with the desired `-Port`.
