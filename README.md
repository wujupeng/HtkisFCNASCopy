# HtkisFCNASCopy

面向 macOS → Windows/Linux SMB 共享目录的大文件上传/下载工具，支持断点续传与进度显示。适用于在局域网/内网环境下，把备份镜像、大型压缩包、视频等稳定传输到 NAS/服务器共享目录，或从共享目录拉回到本地。

## 功能概览

- 大文件上传到 SMB：支持断点续传（中断后可继续）
- 从 SMB 下载到本地：支持断点续传
- 下载支持多选：可同时选择多个文件/文件夹（会递归下载文件夹内所有文件）
- 进度显示：百分比、已传输/总大小、速度
- 结果状态：完成/失败与退出码
- SMB 目标可选择：支持在 Finder 挂载后的共享目录内选择上传目标子目录

## 适用场景

- macOS 电脑向 Windows/Linux/NAS 的 SMB 共享目录传输大文件，网络抖动/休眠/断线后继续传输
- 从共享目录按需下载多个文件/目录到本机 Downloads 或自定义目录
- 备份镜像/项目归档/素材库等需要“可恢复传输”的场景

## 运行环境

- macOS 13+（应用内使用 Finder 挂载与 `/Volumes` 访问共享）
- 目标端：Windows / Linux / NAS，提供 SMB 共享即可
- 网络：局域网/内网环境更佳（跨公网请自行确保 VPN/安全策略）

## 安装与使用（推荐：桌面应用）

1. 打开 DMG 安装包，将 `HtkisFCNASCopy.app` 拖入 `Applications`。
2. 打开应用：
   - **上传**：选择本地源文件 → 填写/选择目标 `smb://HOST/SHARE/...` → 开始
   - **下载**：填写共享根目录 `smb://HOST/SHARE` → 选择要下载的文件/文件夹（可多选）→ 选择本地保存目录 → 开始
3. 传输中可点击“停止”。之后再次点击“开始”会继续未完成部分。

> 说明：应用未做 Apple 公证（notarization）。首次打开如被系统拦截，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。

## CLI 使用（命令行）

仓库也包含两个 Swift 命令行工具，适合脚本化或不使用 GUI 的场景。

### 上传：resume-smb-copy

```
resume-smb-copy <src> <dest> [options]

dest:
  /path/to/dir-or-file
  smb://HOST/SHARE[/subdir]

Options:
  --chunk-mib N       Chunk size in MiB (default: 8)
  --overwrite         Overwrite if destination file exists
  --force             Force resume even if source changed / partial inconsistent
  --verify            Verify sha256 after transfer (slower)
  --quiet             Reduce output
  --mount-timeout N   Wait up to N seconds for Finder mount (default: 60)
```

示例：

```bash
./resume-smb-copy "/Users/me/Downloads/big.iso" "smb://192.168.2.128/systembackup"
```

### 下载：resume-smb-download

```
resume-smb-download <src> <dest> [options]
resume-smb-download <src1> <src2> ... <destDir> [options]

src:
  /path/to/file
  /path/to/dir
  smb://HOST/SHARE/path/to/file-or-dir

dest:
  /path/to/dir-or-file   (local macOS path)
```

示例（多选下载到本地目录）：

```bash
./resume-smb-download \
  "smb://192.168.2.128/systembackup/Movies" \
  "smb://192.168.2.128/systembackup/backup.zip" \
  "/Users/me/Downloads"
```

## 断点续传机制说明

- 传输过程中会在目标目录生成临时文件：`<文件名>.part`
- 同时生成元数据：`<文件名>.resume.json`
- 再次执行同一目标时，会读取 `.part` 的已写入大小，从断点继续写入
- 传输完成后：
  - `.part` 会原子性重命名为最终文件名
  - `.resume.json` 会删除

## SMB 挂载与路径规则（重要）

macOS 通过 Finder 挂载 SMB 后，共享会出现在 `/Volumes/<共享名>`。本项目对 `smb://HOST/SHARE/...` 的处理方式是：

- 尝试解析为 `/Volumes/<共享名>/...` 的本地路径进行读写
- 如果未挂载，会调用 `open smb://...` 触发 Finder 挂载，并在超时时间内轮询等待挂载完成
- 为避免“共享名大小写不一致导致写到本机同名目录”的问题：
  - 会在 `/Volumes` 中按不区分大小写查找真实挂载点
  - 且要求该路径必须是挂载点（不是普通目录）

## 退出码与错误信息

- `0`：成功
- `2`：参数错误或传输失败（错误原因会以 `Error: ...` 输出）

常见错误含义（简要）：

- `SMB share not mounted` / `SMB mount timeout`：共享未挂载或挂载等待超时
- `Destination exists`：目标已存在且未指定 `--overwrite`
- `Source file changed`：源文件大小/修改时间与上次续传记录不一致（可用 `--force`）
- `Verification failed`：开启 `--verify` 后哈希校验失败

## 从源码构建（可选）

本仓库既包含 Swift Package 的核心代码，也保留了独立 Swift 脚本/打包流程。

- 编译命令行工具：

```bash
swiftc resume_smb_copy_swift.swift -O -o resume-smb-copy
swiftc resume_smb_download_swift.swift -O -o resume-smb-download
```

- 生成应用（示例，仅供参考）：

```bash
mkdir -p HtkisFCNASCopy.app/Contents/MacOS HtkisFCNASCopy.app/Contents/Resources
swiftc -parse-as-library DesktopApp.swift -O -o HtkisFCNASCopy.app/Contents/MacOS/HtkisFCNASCopy
```

## 版本信息

- 应用名称：HtkisFCNASCopy
- `CFBundleShortVersionString`：1.0
- `CFBundleVersion`：1

