# CI：上游 push → 本地自动构建 → Google Drive 分发

上游 `the-dissidents/subtle` 每次 push，都自动在**你自己的 Windows 机器**上构建出 Windows 产物，
并上传到 Google Drive 的固定文件夹，协作者用一个**永久不变的文件夹链接**下载。

```
上游 the-dissidents/subtle  (push)
   └─ .github/workflows/notify-fork-build.yml   ← 提交到上游（本仓库 ci/upstream/ 里有副本）
        └─ repository_dispatch (upstream-push) ─────────────┐
                                                            ▼
fork AphrixZjr/subtle
   └─ .github/workflows/local-build-on-dispatch.yml   (on: repository_dispatch)
        └─ runs-on: [self-hosted, windows, subtle-build]    ← 跑在你本机
             ├─ 同步上游代码 (git fetch upstream + merge)
             ├─ build-windows-local.ps1
             └─ ci/upload-to-gdrive.ps1  → rclone(OAuth) → My Drive 文件夹
```

为什么本地构建：Windows 构建强依赖本机环境（MSYS2 + 注册表、LLVM 18.x、MSVC、Windows SDK、fnm/pnpm），
无法在 GitHub 托管 runner 上跑，所以用**自托管 runner** 在你机器上执行。

---

## 文件清单

| 文件 | 说明 |
|---|---|
| `../.github/workflows/local-build-on-dispatch.yml` | fork 侧监听 workflow（自托管 runner） |
| `upstream/notify-fork-build.yml` | 提交到**上游**的 dispatch workflow（拷进上游 `.github/workflows/`） |
| `upload-to-gdrive.ps1` | 找产物 + rclone 上传 + 打印稳定链接 |
| `rclone.conf.example` | rclone OAuth 配置模板（真文件 `rclone.conf` 不提交） |
| `ci.env.example` | 非敏感配置模板（真文件 `ci.env` 不提交） |

真实密钥文件（`rclone.conf`、`ci.env`）已被 `.gitignore` 忽略，**不要提交**。

---

## A. 本机自托管 Runner（一次性）

1. fork 仓库 → **Settings → Actions → Runners → New self-hosted runner**（Windows x64），按页面命令安装。
2. 配置时添加标签：`windows,subtle-build`（`self-hosted` 自动带）——需与 workflow 的 `runs-on` 完全一致。
3. 用**能访问你构建环境的账户**运行（能读到 MSYS2/LLVM/fnm/PATH）。建议先用交互式 `run.cmd` 验证，再按需装成服务。
4. 安装 rclone 到 PATH：`winget install Rclone.Rclone`。

## B. Google Cloud + Google Drive（个人 My Drive，OAuth）

> 无 Google Workspace，因此用**个人 My Drive + OAuth 用户令牌**（服务账号在个人 My Drive 无存储配额，会上传失败）。

1. [Google Cloud Console](https://console.cloud.google.com/) 建项目 → **启用 Google Drive API**。
2. **OAuth 同意屏幕**：User type 选 **External**，填基本信息；**Test users** 里加上你自己的 Google 邮箱。
   - 停在 Testing 状态即可；注意此时 refresh token 约 7 天过期（见「维护」）。
3. **凭据 → 创建 OAuth 客户端 ID → 应用类型 Desktop app**，记下 `client_id` 与 `client_secret`。
4. 在 My Drive 建固定文件夹（如 `subtle-windows-builds`）；从 URL `.../folders/<ID>` 记下**文件夹 ID**。
5. 该文件夹 → 共享 → **“知道链接的任何人 = 查看者”**，把文件夹链接发给协作者（永久稳定）。
6. 在 **runner 机器**上生成 rclone remote：
   ```powershell
   rclone config
   # n) 新建 → name: gdrive → storage: drive
   # client_id / client_secret 填步骤 3 的值
   # scope: 1 (drive 全权限)
   # 剩余默认；auto config 选 y，浏览器用步骤 2 的测试账号完成授权
   # 完成后编辑该 remote，设 root_folder_id = 步骤 4 的文件夹 ID（或后续用 --drive-root-folder-id 覆盖）
   ```
   把生成的配置拷到常驻路径：
   ```powershell
   mkdir C:\subtle-ci -Force
   copy "$env:APPDATA\rclone\rclone.conf" C:\subtle-ci\rclone.conf
   ```
   验证：
   ```powershell
   rclone --config C:\subtle-ci\rclone.conf lsd gdrive:
   ```

## C. fork 仓库 变量/密钥（AphrixZjr/subtle → Settings → Secrets and variables → Actions）

- **Variable** `GDRIVE_FOLDER_ID` = My Drive 目标文件夹 ID（非敏感）。
- rclone 令牌**默认不入库**——常驻 runner 的 `C:\subtle-ci\rclone.conf`（workflow 里 `RCLONE_CONFIG` 指向它）。
- 备选（想让 workflow 自包含）：把整份 `rclone.conf` 存成 **Secret** `RCLONE_CONF`，在 workflow 里加一步写入临时文件并让 `RCLONE_CONFIG` 指向它。代价：rclone 续期的 access token 无法写回，但 refresh token 仍有效，可接受。

## D. 上游仓库（the-dissidents/subtle，需 maintainer 配合）

1. 把 `ci/upstream/notify-fork-build.yml` 作为 PR 提交到上游 `.github/workflows/notify-fork-build.yml`。
2. 上游 **Settings → Secrets and variables → Actions**：
   - **Variable** `FORK_DISPATCH_REPO` = `AphrixZjr/subtle`
   - **Secret** `FORK_DISPATCH_PAT` = 能对你 fork 触发 dispatch 的 token
3. PAT：细粒度 token，仅授权 `AphrixZjr/subtle`，权限 **Contents: Read and write** + **Metadata: Read**（`repository_dispatch` 需写权限）；或经典 token `repo` scope。**由你生成、交给上游存**。
   - ⚠️ 这是把一个能写你 fork 的 token 托管给上游。介意的话改用「退路：fork 轮询」。

### 退路：fork 轮询（不依赖上游、不托管 PAT）

若上游不接受 PR，可在 fork 加一个 `schedule` workflow 定期比对上游 HEAD：
```yaml
on:
  schedule:
    - cron: "*/15 * * * *"   # 每 15 分钟
  workflow_dispatch:
```
job 里 `git ls-remote https://github.com/the-dissidents/subtle.git HEAD` 取最新 SHA，
与上次构建记录（缓存/artifact/仓库文件）比对，有变化则触发本地构建同样的步骤。
代价：有轮询延迟；本次未实现。

---

## 手动运行 / 验证

```powershell
# 1) 凭据 & 上传单测（先有一个 zip，或先跑构建）
rclone --config C:\subtle-ci\rclone.conf lsd gdrive:
$env:RCLONE_CONFIG = 'C:\subtle-ci\rclone.conf'; $env:GDRIVE_FOLDER_ID = '<文件夹ID>'
./ci/upload-to-gdrive.ps1

# 2) 构建脚本非交互（不应卡在 Press Enter、不应弹资源管理器）
$env:CI = 'true'; ./build-windows-local.ps1

# 3) Runner 手动触发：fork → Actions → "Local Windows build on upstream push" → Run workflow

# 4) dispatch 链路：上游 push 一次，或手动打信号：
#   curl -X POST -H "Authorization: Bearer <PAT>" \
#     -H "Accept: application/vnd.github+json" \
#     https://api.github.com/repos/AphrixZjr/subtle/dispatches \
#     -d '{"event_type":"upstream-push","client_payload":{"sha":"<sha>"}}'

# 5) 协作者视角：无痕窗口打开文件夹链接，确认未登录也能下载最新产物。
```

## 维护 / 注意

- **OAuth Testing 状态**：refresh token 约 7 天过期，届时 `rclone config reconnect gdrive:` 重新授权。
  想长期免维护，可把 OAuth 同意屏幕「发布」为 Production（个人账号可自审）。
- 产物占用你个人 **15GB** 配额，定期清理旧版本（文件夹里按 SHA 命名，便于识别）。
- runner 需**常驻开机**才能接信号；关机期间的上游 push 需靠下次触发或手动补跑。
- 上游 push 频繁时 workflow 的 `concurrency.cancel-in-progress` 只保留最新构建。
