# CI：上游更新 → 本机 Windows 构建 → Google Drive 分发

本仓库在自己的 Windows self-hosted runner 上构建 `the-dissidents/subtle` 的最新代码，验证 ZIP 后上传到固定的 Google Drive 文件夹。协作者始终使用同一个只读链接下载。

```text
the-dissidents/subtle main
   ├─ 可选：repository_dispatch（上游接受通知 workflow 后可即时触发）
   └─ 兜底：fork 每 15 分钟轮询 upstream/main
                         │
                         ▼
AphrixZjr/subtle 默认分支上的 local-build-on-dispatch.yml
   └─ self-hosted / Windows / X64 / subtle-build runner
        ├─ controller/：fork 的可信 CI 脚本
        ├─ source/：从上游仓库按 branch/tag/SHA 独立 checkout
        ├─ 把三个 Windows 构建脚本覆盖到 source/ 后构建
        ├─ 验证本次 ZIP、subtle.exe、时间、大小和 SHA-256
        └─ rclone OAuth → subtle-windows-builds
```

## 当前固定资源

- Drive 文件夹：[`subtle-windows-builds`](https://drive.google.com/drive/folders/1Y2Cutr-QaUggJv4VOVc0jfw6eVF3F5nn)
- 文件夹 ID：`1Y2Cutr-QaUggJv4VOVc0jfw6eVF3F5nn`
- 共享权限：知道链接的任何人 = 查看者
- runner：`LAPTOP-IJR4CTRE`，注册到 `AphrixZjr/subtle`
- runner 安装目录：`D:\actions-runner`
- rclone：`C:\subtle-ci\rclone.exe`
- rclone 配置：`C:\subtle-ci\rclone.conf`
- 本地代理：`http://127.0.0.1:10808`（v2rayN；访问 Google API 时必须运行）

`C:\subtle-ci` 已限制为当前 Windows 账号和 SYSTEM 可访问。仓库内的 `ci/rclone.conf`、`ci/client.json`、`ci/client_secret*.json` 和 `ci/ci.env` 均被忽略，不得提交。

## 文件清单

| 文件 | 说明 |
|---|---|
| `../.github/workflows/local-build-on-dispatch.yml` | fork 侧监听、轮询、构建和上传 workflow |
| `upstream/notify-fork-build.yml` | 可选的上游即时通知 workflow |
| `../build-windows-local.ps1` | 本机构建包装器与 MSYS2 探测 |
| `upload-to-gdrive.ps1` | 严格验证本次产物并用 rclone 上传 |
| `rclone.conf.example` | rclone OAuth 配置结构示例（不含真实值） |
| `ci.env.example` | 本地非敏感参数示例 |

## A. Self-hosted runner

workflow 使用 GitHub 默认标签和该机器的专用标签：

```yaml
runs-on: [self-hosted, windows, x64, subtle-build]
```

现有 runner 已注册并可用，但当前以交互式 `run.cmd` 运行；Windows 注销、重启或关闭终端后需要重新启动。若要长期无人值守，应按 GitHub runner 文档改为服务或计划任务，并确保运行账号能访问：

- MSYS2、LLVM 18、MSVC 与 Windows SDK
- fnm/Node、pnpm、cargo
- `C:\subtle-ci`
- 本机 v2rayN 代理

`subtle-build` 已分配给 `LAPTOP-IJR4CTRE`，可确保拥有 rclone、工具链和本机 marker 的机器接单。若重新注册 runner，必须重新添加该标签。

## B. Google Drive 与 rclone

本机已用个人 My Drive OAuth 完成配置。目标文件夹是 rclone remote 的根目录，workflow 也会显式传入 folder ID。

手动验证（不会显示配置内容）：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:10808'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
$env:NO_PROXY = '127.0.0.1,localhost'

C:\subtle-ci\rclone.exe --config C:\subtle-ci\rclone.conf lsf gdrive:
```

OAuth 应用当前若仍为 **Testing**：

- 授权账号必须在 Google Auth Platform → Audience → Test users 中；
- offline refresh token 约 7 天后失效；
- 到期后重新执行 `rclone config reconnect gdrive:`；
- 要长期无人值守，应按 Google 的个人用途规则评估发布为 Production，并接受相应的未验证应用提示或验证要求。

## C. fork workflow

`.github/workflows/local-build-on-dispatch.yml` 必须存在于 fork 的默认分支，`schedule`、`workflow_dispatch` 和 `repository_dispatch` 才能可靠运行。
公开仓库 fork 还需在 **Actions** 页明确启用 Actions/该 workflow；长期无活动时 GitHub 可能自动停用 schedule，需要重新启用。

支持三种触发：

1. `repository_dispatch`：上游即时通知，事件类型 `upstream-push`；
2. `workflow_dispatch`：手动输入上游 branch、tag 或完整 40 位 SHA；留空构建 `upstream/main`；
3. `schedule`：每 15 分钟检查 `upstream/main`。

轮询成功上传后把上游 SHA 与 CI controller SHA 记录到：

```text
C:\subtle-ci\last-successful-build-key
```

上游和 controller 均未变化时不重复构建；因此修改 CI 脚本后也会自动重跑。schedule 与 dispatch 共用“main updates”并发组，只保留一个待运行的最新主线信号；手动 branch/tag/SHA 使用基于 `run_id` 的唯一组，不会被后续 schedule 替换。运行中的完整构建不允许被新轮询取消，避免超过 15 分钟时持续饥饿。

仓库 Variable `GDRIVE_FOLDER_ID` 可覆盖目标。当前 workflow 带有该 fork 专用的非敏感默认 ID，因此未设置 Variable 也能运行。

源码阶段具有以下保护：

- controller 与 source 使用两个独立 checkout 目录；
- source checkout 明确指定 `the-dissidents/subtle`，fork-only SHA 无法混入；
- dispatch 只接受 `refs/heads/main` 与完整 40 位 SHA，并验证实际 checkout 等于该 SHA；
- branch/tag/SHA 构建的是独立 source checkout 的对应 commit，不会因 merge 已是 ancestor 而静默构建较新代码；
- 只把 fork 中受控的三个 Windows 构建脚本覆盖到 source；
- step outputs 传递 SHA 与产物路径，构建脚本不能通过 `GITHUB_ENV` 改写 marker 控制状态；
- 记录实际 upstream SHA 与 controller SHA。

## D. 可选：上游即时通知

fork 的定时轮询已能独立工作。若仍希望上游每次 push 后立即触发：

1. 把 `ci/upstream/notify-fork-build.yml` 提交为上游的 `.github/workflows/notify-fork-build.yml`；
2. 上游配置 Variable `FORK_DISPATCH_REPO=AphrixZjr/subtle`；
3. 上游配置 Secret `FORK_DISPATCH_PAT`，其 token 仅授权 `AphrixZjr/subtle` 的 repository dispatch 所需写权限。

通知 workflow 只监听 `main`，用 `jq` 生成 JSON，避免把 ref/actor 直接插入 shell heredoc。若不愿把 fork 写 token 托管给上游，保持轮询即可。

## 构建与上传验证

本机手动构建：

```powershell
$env:CI = 'true'
./build-windows-local.ps1
```

手动上传当前版本的确切 ZIP：

```powershell
$version = (Get-Content package.json -Raw | ConvertFrom-Json).version
$artifact = Join-Path $PWD "src-tauri\target\release\subtle $version windows x64.zip"
$env:RCLONE_EXE = 'C:\subtle-ci\rclone.exe'
$env:RCLONE_CONFIG = 'C:\subtle-ci\rclone.conf'
$env:GDRIVE_FOLDER_ID = '1Y2Cutr-QaUggJv4VOVc0jfw6eVF3F5nn'
$env:HTTP_PROXY = 'http://127.0.0.1:10808'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
./ci/upload-to-gdrive.ps1 -ArtifactPath $artifact
```

上传器拒绝：release 目录外文件、空文件、早于本次构建的 ZIP、缺少或重复 `subtle.exe` 的 ZIP，以及远端读回大小不一致的文件。

## 安全与维护

- workflow 使用 `contents: read`，checkout 不持久化 GitHub 凭据。
- OAuth 配置拥有 Drive 权限；runner 应使用专用低权限 Windows 账号或隔离虚拟机，不存放其它敏感文件。
- 上游代码会在同一账号下执行，常驻 Drive token 无法形成强安全边界；高安全场景应把构建与上传拆到不同 runner/账号。
- v2rayN 必须在上传和 token 刷新时运行；代理改变后同步更新 workflow 或 Windows 系统代理。
- Drive 个人配额有限，应定期清理旧 SHA 产物。
- 用无痕窗口检查固定文件夹链接，确认未登录用户只能查看和下载。
