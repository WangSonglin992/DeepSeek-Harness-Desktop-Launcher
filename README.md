# DeepSeek Harness Desktop Launcher

一个面向 Windows + WSL2 的轻量桌面启动器。双击桌面上的 **DeepSeek Harness** 图标即可在后台启动官方 DeepSeek Harness Web UI；关闭专用应用窗口后，对应的 WSL 服务也会自动停止。

![DeepSeek Harness launcher icon](assets/DeepSeek-Harness.png)

## 特性

- 不显示命令提示符或 PowerShell 窗口。
- 安装时通过 pnpm 部署官方最新版，日常启动直接使用本地运行时，避免 npm/npx 的重复依赖解析。
- 使用独立 Microsoft Edge 应用窗口，不与日常浏览器标签页混在一起。
- 关闭应用窗口后，只终止本次启动器创建的 WSL 进程组。
- 自动识别默认 WSL 发行版、Linux HOME、Windows 用户目录和 Edge 路径。
- 不包含、复制或上传 API key、DeepSeek 凭据、会话、日志或浏览器 profile。

## 环境要求

- Windows 10/11 x64，已启用 WSL2。
- 一个可用的 WSL Linux 发行版，包含 `bash`、`setsid`、`ps`、`awk`、`grep`、`tail`。
- WSL 内已安装 Node.js 与 pnpm。
- Windows 已安装 Microsoft Edge。

DeepSeek Harness 的账号、API 凭据和配置由目标电脑上的官方 Harness 自行管理。本仓库不会在电脑之间同步这些数据。

## 安装

在 Windows PowerShell 中运行：

```powershell
git clone https://github.com/WangSonglin992/DeepSeek-Harness-Desktop-Launcher.git
cd DeepSeek-Harness-Desktop-Launcher
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

如果需要指定非默认 WSL 发行版：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Distro Ubuntu-24.04
```

安装器会创建：

- `%LOCALAPPDATA%\DeepSeek Harness`：启动器运行文件。
- `%PROGRAMDATA%\DeepSeekHarness`：供 Windows Shell 读取的版本化图标缓存。
- `%USERPROFILE%\Desktop\DeepSeek Harness.lnk`：桌面快捷方式。

快捷方式会直接指向已安装的 VBS 启动器，避免 `wscript.exe` 命令行对带空格脚本路径的引号解析问题。图标路径会以不含环境变量的绝对路径写入；每次安装都会重建 `.lnk`，并立即校验启动目标、图标路径与 ICO 内容。

安装完成后双击桌面图标即可。首次使用时，如果官方 Harness 要求登录或配置，请在其页面中完成；凭据只保存在该电脑的官方 Harness 用户目录。

## 更新

```powershell
git pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

重复运行安装器会更新启动器、图标和 WSL 中的官方 Harness 运行时，不会删除 `~/.dsh` 或 pnpm 缓存。

## 卸载

先关闭 DeepSeek Harness 应用窗口，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

卸载器只删除桌面快捷方式、`%LOCALAPPDATA%\DeepSeek Harness` 和 `%PROGRAMDATA%\DeepSeekHarness` 图标缓存。它不会删除 WSL、Node.js、pnpm 缓存、Harness 运行时或 `~/.dsh` 中的官方配置与会话。

## 重新生成图标

正常安装不需要 Python；仓库已经包含生成好的 ICO。如果要从源 PNG 重新构建，需要 Python 3 与 Pillow：

```powershell
python -m pip install -r requirements-dev.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Icon.ps1
```

构建脚本只进行本地图像裁边、透明背景处理和多尺寸 ICO 转换，不访问网络服务。

## 安全边界

仓库采用文件白名单安装，不会复制当前电脑的整个 `%LOCALAPPDATA%\DeepSeek Harness` 目录。以下内容明确排除：

- `~/.dsh/.credentials.yaml`、环境变量和任何 API key。
- `~/.dsh` 中的 settings、sessions、storages 与 profiles。
- `launcher.log`、`EdgeProfile` 和生成的 `launcher-config.json`。
- pnpm 缓存、Harness 运行时及其他项目文件。

运行 `scripts\Test-Package.ps1` 可以执行 PowerShell/Bash 语法检查、快捷方式启动与图标路径回归测试、隔离安装检查和敏感信息扫描，不会调用模型 API。

## 说明

本项目是非官方桌面启动辅助工具。DeepSeek Harness 由 DeepSeek 提供；本启动器仅调用其公开 npm 包，不修改 Harness 本身。图标源图由仓库所有者提供，未包含在代码许可证授权范围内。
