# Windows 构建指南

## 最小环境依赖

| 依赖 | 版本 |
|---|---|
| Visual Studio 2022 Community（含「使用 C++ 的桌面开发」+ Windows SDK） | 17.14.21（MSVC 14.44.35207，SDK 10.0.26100） |
| MSYS2 · make | 4.4.1 |
| MSYS2 · nasm | 2.16.03 |
| MSYS2 · diffutils | 3.12 |
| MSYS2 · pkgconf | 2.5.1 |
| Rust（rustup，host `x86_64-pc-windows-msvc`） | 1.96.1 |
| Node.js | 25.2.0 |
| pnpm | 11.10.0 |
| LLVM / libclang | 18.1.8 |
| Git | 2.42.0 |

以上版本在本机实测通过。构建时已尝试探测依赖版本下限，但不保证为最低版本。

## 从零配置

```powershell
# 1) Rust（MSVC host）
winget install --id Rustlang.Rustup -e --accept-package-agreements --accept-source-agreements
rustup default stable          

# 2) Node 25.2.0
winget install --id Schniz.fnm -e --accept-package-agreements --accept-source-agreements
fnm install 25.2.0
fnm use 25.2.0

# 3) pnpm
npm install -g pnpm            
```

```bash
# 4) MSYS2 构建工具
pacman -Sy --noconfirm
pacman -S --needed --noconfirm make diffutils pkgconf nasm
```

```powershell
# 5) libclang（18.x）
#   标准做法（管理员）：安装官方 LLVM 18.x 到 C:\Program Files\LLVM，脚本自动探测。
#   若无法写入 Program Files / 无法提权：解压官方 18.x 安装包获取 libclang.dll，运行下述命令：
setx LIBCLANG_PATH "C:\path\to\libclang\bin" 
```

构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-windows.ps1
```

## 问题排查

- **libclang 与新版 clang 不兼容（`error[E0080] … would overflow`）**：改用 LLVM **18.x**，或用`LIBCLANG_PATH` 指向 18.x 的 `libclang.dll`。不应使用 MSYS2/mingw 的 libclang。
- **`RC.EXE not found`（tauri-winres）**：已经在脚本中设置 `$env:RC`解决。若仍缺失，需要在 VS Installer 安装「Windows 10/11 SDK」组件。
- **找不到 `cl.exe` / vcvars 未生效**：脚本已改为以完整路径调用 `vcvars64.bat`。
- **`ERR_PNPM_IGNORED_BUILDS` 错误使 pnpm 退出码非 0**：脚本使用 `pnpm install --ignore-scripts` 和 `npm_config_verify_deps_before_run=false` 配置项规避。
- **PowerShell 5.1 下原生命令误抛异常**：脚本已改用本地 CLI / 局部 `Continue` 规避。
