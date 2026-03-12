import AppKit
import Foundation
import SwiftUI

func relativePath(from root: URL, to file: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = file.standardizedFileURL.path
    if filePath == rootPath { return "" }
    let prefix = rootPath.hasSuffix("/") ? rootPath : (rootPath + "/")
    if filePath.hasPrefix(prefix) {
        return String(filePath.dropFirst(prefix.count))
    }
    return file.lastPathComponent
}

func isMountPoint(_ url: URL) -> Bool {
    var st = stat()
    var pst = stat()
    let parent = url.deletingLastPathComponent()
    if lstat(url.path, &st) != 0 { return false }
    if lstat(parent.path, &pst) != 0 { return false }
    return st.st_dev != pst.st_dev
}

func findMountedShareDirectory(caseInsensitive share: String) -> URL? {
    let vols = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    guard let items = try? FileManager.default.contentsOfDirectory(at: vols, includingPropertiesForKeys: nil) else {
        return nil
    }
    let target = share.lowercased()
    for u in items {
        if u.lastPathComponent.lowercased() == target, isMountPoint(u) {
            return u
        }
    }
    return nil
}

class TransferBaseModel: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var progressFraction: Double = 0
    @Published var progressText: String = ""
    @Published var statusText: String = ""
    @Published var exitCodeText: String = ""
    @Published var lastErrorText: String = ""
    @Published var logText: String = ""

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrBuffer = Data()
    private var stdoutBuffer = Data()

    func clearLog() {
        logText = ""
    }

    func stop() {
        guard isRunning, let p = process else { return }
        p.terminate()
        statusText = "已停止（可再次点击开始继续）"
    }

    func startProcess(executableName: String, arguments: [String], startText: String, runningText: String) {
        guard !isRunning else { return }
        guard let toolURL = Bundle.main.url(forResource: executableName, withExtension: nil) else {
            statusText = "找不到内置工具（\(executableName)）"
            return
        }

        isRunning = true
        progressFraction = 0
        progressText = ""
        exitCodeText = ""
        lastErrorText = ""
        statusText = startText
        stderrBuffer = Data()
        stdoutBuffer = Data()

        let p = Process()
        p.executableURL = toolURL
        p.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        stdoutPipe = out
        stderrPipe = err

        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { return }
            DispatchQueue.main.async {
                self.consumeStderrData(d)
            }
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { return }
            DispatchQueue.main.async {
                self.consumeStdoutData(d)
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.isRunning = false
                self.exitCodeText = "退出码：\(proc.terminationStatus)"
                if proc.terminationStatus == 0 {
                    if self.progressFraction < 1 {
                        self.progressFraction = 1
                    }
                    if self.statusText.isEmpty || self.statusText == runningText {
                        self.statusText = "完成"
                    }
                } else {
                    if self.statusText.isEmpty || self.statusText == runningText {
                        self.statusText = "失败（退出码 \(proc.terminationStatus)）"
                    }
                    if self.lastErrorText.isEmpty {
                        self.lastErrorText = "未知错误"
                    }
                }
            }
        }

        do {
            try p.run()
            process = p
            statusText = runningText
        } catch {
            isRunning = false
            statusText = "启动失败：\(error.localizedDescription)"
        }
    }

    private func consumeStderrData(_ d: Data) {
        stderrBuffer.append(d)
        while true {
            guard let range = stderrBuffer.firstRange(of: Data([0x0A])) else { break }
            let lineData = stderrBuffer.subdata(in: 0..<range.lowerBound)
            stderrBuffer.removeSubrange(0...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                handleStderrLine(line)
            }
        }
    }

    private func consumeStdoutData(_ d: Data) {
        stdoutBuffer.append(d)
        while true {
            guard let range = stdoutBuffer.firstRange(of: Data([0x0A])) else { break }
            let lineData = stdoutBuffer.subdata(in: 0..<range.lowerBound)
            stdoutBuffer.removeSubrange(0...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                handleStdoutLine(line)
            }
        }
    }

    private func handleStderrLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        if let (fraction, formatted) = parseProgressLine(trimmed) {
            progressFraction = fraction
            progressText = formatted
            appendLog(trimmed + "\n")
            return
        }
        if trimmed.hasPrefix("Error:") {
            lastErrorText = trimmed
            statusText = "失败（传输中断）"
        } else if !trimmed.contains("%") {
            lastErrorText = trimmed
        }
        appendLog(trimmed + "\n")
    }

    private func handleStdoutLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if trimmed.hasPrefix("Done:") {
            statusText = "完成"
            progressFraction = 1
        }
        appendLog(trimmed + "\n")
    }

    private func parseProgressLine(_ line: String) -> (Double, String)? {
        if !(line.contains("%") && line.contains("/") && line.contains("/s")) {
            return nil
        }
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)%\s+(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: line, range: range) else { return nil }
        let pctStr = ns.substring(with: m.range(at: 1))
        guard let pct = Double(pctStr) else { return nil }
        let fraction = max(0, min(1, pct / 100.0))
        let rest = m.numberOfRanges >= 3 ? ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
        return (fraction, rest)
    }

    private func appendLog(_ s: String) {
        let next = logText + s
        if next.count > 200_000 {
            logText = String(next.suffix(200_000))
        } else {
            logText = next
        }
    }
}

final class UploadModel: TransferBaseModel {
    @Published var sourcePath: String = ""
    @Published var smbURL: String = "smb://192.168.2.128/systembackup"

    func chooseDest() {
        guard !isRunning else { return }
        guard smbURL.lowercased().hasPrefix("smb://") else {
            statusText = "目标必须是 smb:// 开头"
            return
        }
        do {
            let (mountedPath, host, share) = try ensureSMBMountedAndResolvePath(smbURL, timeoutSeconds: 60)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            panel.canCreateDirectories = true
            panel.title = "选择上传到的 SMB 目录"
            if FileManager.default.fileExists(atPath: mountedPath.path) {
                panel.directoryURL = mountedPath
            } else {
                let mountRoot = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share, isDirectory: true)
                if FileManager.default.fileExists(atPath: mountRoot.path) {
                    panel.directoryURL = mountRoot
                } else {
                    panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
                }
            }
            if panel.runModal() == .OK, let url = panel.url {
                let normalized = url.standardizedFileURL
                let parts = normalized.path.split(separator: "/").map(String.init)
                guard parts.count >= 2, parts[0] == "Volumes" else {
                    statusText = "请选择 /Volumes 下的共享目录"
                    return
                }
                let pickedShare = parts[1]
                let relParts = Array(parts.dropFirst(2))
                if relParts.isEmpty {
                    smbURL = "smb://\(host)/\(pickedShare)"
                } else {
                    let encoded = relParts.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
                    smbURL = "smb://\(host)/\(pickedShare)/\(encoded)"
                }
                statusText = "已选择目标目录"
            }
        } catch {
            statusText = "挂载 SMB 失败：\(error.localizedDescription)"
        }
    }

    private func ensureSMBMountedAndResolvePath(_ smb: String, timeoutSeconds: Int) throws -> (URL, String, String) {
        guard let u = URL(string: smb), let host = u.host else {
            throw NSError(domain: "ResumeSMB", code: 10, userInfo: [NSLocalizedDescriptionKey: "无效 smb:// 地址"])
        }
        let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/").map(String.init)
        guard let share = parts.first, !share.isEmpty else {
            throw NSError(domain: "ResumeSMB", code: 11, userInfo: [NSLocalizedDescriptionKey: "缺少共享名"])
        }

        let mountRoot = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share, isDirectory: true)
        if !FileManager.default.fileExists(atPath: mountRoot.path) || !isMountPoint(mountRoot) {
            let shareURL = "smb://\(host)/\(share)"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [shareURL]
            try? p.run()
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: mountRoot.path), isMountPoint(mountRoot) { break }
                if let mounted = findMountedShareDirectory(caseInsensitive: share) { _ = mounted; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        var actualMountRoot = mountRoot
        if !FileManager.default.fileExists(atPath: actualMountRoot.path) || !isMountPoint(actualMountRoot) {
            if let mounted = findMountedShareDirectory(caseInsensitive: share) {
                actualMountRoot = mounted
            }
        }

        if !FileManager.default.fileExists(atPath: actualMountRoot.path) || !isMountPoint(actualMountRoot) {
            throw NSError(domain: "ResumeSMB", code: 12, userInfo: [NSLocalizedDescriptionKey: "等待挂载超时"])
        }

        var mountedPath = actualMountRoot
        for p in parts.dropFirst() {
            mountedPath.appendPathComponent(p, isDirectory: true)
        }
        return (mountedPath, host, actualMountRoot.lastPathComponent)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canCreateDirectories = false
        panel.title = "选择要上传的大文件"
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
        }
    }

    func start() {
        guard !isRunning else { return }
        guard !sourcePath.isEmpty else {
            statusText = "请选择源文件"
            return
        }
        guard smbURL.lowercased().hasPrefix("smb://") else {
            statusText = "目标必须是 smb:// 开头"
            return
        }

        startProcess(
            executableName: "resume-smb-copy",
            arguments: [sourcePath, smbURL],
            startText: "启动上传…",
            runningText: "上传中（可随时停止，之后可继续）"
        )
    }
}

final class DownloadModel: TransferBaseModel {
    @Published var smbBrowseRoot: String = "smb://192.168.2.128/systembackup"
    @Published var selectedSources: [String] = []
    @Published var localDestDir: String = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())

    func chooseSources() {
        guard !isRunning else { return }
        do {
            let mountBase = try ensureSMBMountedAndGetMountBase()
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.resolvesAliases = true
            panel.canCreateDirectories = false
            panel.title = "选择要下载的文件/文件夹（可多选）"
            panel.directoryURL = mountBase
            if panel.runModal() == .OK {
                selectedSources = panel.urls.map(\.path).sorted()
                statusText = "已选择 \(selectedSources.count) 个项目"
            }
        } catch {
            statusText = "挂载 SMB 失败：\(error.localizedDescription)"
        }
    }

    func chooseDestDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canCreateDirectories = true
        panel.title = "选择下载到的本地目录"
        if panel.runModal() == .OK, let url = panel.url {
            localDestDir = url.path
        }
    }

    private func ensureSMBMountedAndGetMountBase(timeoutSeconds: Int = 60) throws -> URL {
        if !smbBrowseRoot.lowercased().hasPrefix("smb://") {
            throw NSError(domain: "ResumeSMB", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入 smb:// 根目录"])
        }
        guard let u = URL(string: smbBrowseRoot), let host = u.host else {
            throw NSError(domain: "ResumeSMB", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效 smb:// 地址"])
        }
        let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/").map(String.init)
        guard let share = parts.first, !share.isEmpty else {
            throw NSError(domain: "ResumeSMB", code: 3, userInfo: [NSLocalizedDescriptionKey: "缺少共享名"])
        }
        let mountBase = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share, isDirectory: true)
        if FileManager.default.fileExists(atPath: mountBase.path), isMountPoint(mountBase) {
            return mountBase
        }
        if let mounted = findMountedShareDirectory(caseInsensitive: share) {
            return mounted
        }
        let shareURL = "smb://\(host)/\(share)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [shareURL]
        try? p.run()
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: mountBase.path), isMountPoint(mountBase) {
                return mountBase
            }
            if let mounted = findMountedShareDirectory(caseInsensitive: share) {
                return mounted
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw NSError(domain: "ResumeSMB", code: 4, userInfo: [NSLocalizedDescriptionKey: "等待挂载超时"])
    }

    func start() {
        guard !isRunning else { return }
        guard !selectedSources.isEmpty else {
            statusText = "请选择要下载的文件/文件夹"
            return
        }
        guard !localDestDir.isEmpty else {
            statusText = "请选择本地目录"
            return
        }

        startProcess(
            executableName: "resume-smb-download",
            arguments: selectedSources + [localDestDir],
            startText: "启动下载…",
            runningText: "下载中（可随时停止，之后可继续）"
        )
    }
}

struct TransferStatusView: View {
    @ObservedObject var model: TransferBaseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
            HStack(spacing: 10) {
                Text(String(format: "%.2f%%", model.progressFraction * 100.0))
                    .font(.system(.body, design: .monospaced))
                if !model.progressText.isEmpty {
                    Text(model.progressText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 10) {
                if !model.statusText.isEmpty {
                    Text(model.statusText)
                }
                Spacer()
                if !model.exitCodeText.isEmpty {
                    Text(model.exitCodeText)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.lastErrorText.isEmpty {
                Text(model.lastErrorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

struct UploadView: View {
    @ObservedObject var model: UploadModel

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("源文件") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Button("选择文件") { model.chooseFile() }
                                Spacer()
                                if !model.sourcePath.isEmpty {
                                    Button("清空") { model.sourcePath = "" }
                                }
                            }
                            Text(model.sourcePath.isEmpty ? "未选择" : model.sourcePath)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox("目标（SMB）") {
                        HStack(spacing: 10) {
                            Text("地址：")
                                .frame(width: 56, alignment: .trailing)
                            TextField("", text: $model.smbURL)
                                .textFieldStyle(.roundedBorder)
                            Button("选择目标") { model.chooseDest() }
                                .buttonStyle(.bordered)
                                .disabled(model.isRunning)
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox {
                        HStack(spacing: 10) {
                            Button(model.isRunning ? "上传中…" : "开始上传") { model.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isRunning)
                                .keyboardShortcut(.defaultAction)
                            Button("停止") { model.stop() }
                                .buttonStyle(.bordered)
                                .disabled(!model.isRunning)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox("状态") {
                        TransferStatusView(model: model)
                            .padding(.vertical, 6)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 300)

            GroupBox {
                HStack(spacing: 10) {
                    Text("日志")
                        .font(.headline)
                    Spacer()
                    Button("清空日志") { model.clearLog() }
                        .disabled(model.logText.isEmpty)
                }
                .padding(.bottom, 6)

                TextEditor(text: $model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(minHeight: 220)
        }
    }
}

struct DownloadView: View {
    @ObservedObject var model: DownloadModel
    @State private var selection: Set<String> = []

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("源（SMB）") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text("根目录：")
                                    .frame(width: 70, alignment: .trailing)
                                TextField("", text: $model.smbBrowseRoot)
                                    .textFieldStyle(.roundedBorder)
                                Button("选择源(多选)") { model.chooseSources() }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isRunning)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Text("已选：")
                                        .frame(width: 70, alignment: .trailing)
                                    Text("\(model.selectedSources.count) 个")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("移除所选") {
                                        let toRemove = selection
                                        if !toRemove.isEmpty {
                                            model.selectedSources.removeAll { toRemove.contains($0) }
                                            selection = []
                                        }
                                    }
                                    .disabled(selection.isEmpty || model.isRunning)
                                    Button("清空") {
                                        model.selectedSources = []
                                        selection = []
                                    }
                                    .disabled(model.selectedSources.isEmpty || model.isRunning)
                                }

                                List(selection: $selection) {
                                    ForEach(model.selectedSources, id: \.self) { p in
                                        Text(p)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .frame(height: 150)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox("目标（本地）") {
                        HStack(spacing: 10) {
                            Text("目录：")
                                .frame(width: 56, alignment: .trailing)
                            Text(model.localDestDir.isEmpty ? "未选择" : model.localDestDir)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择目录") { model.chooseDestDir() }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox {
                        HStack(spacing: 10) {
                            Button(model.isRunning ? "下载中…" : "开始下载") { model.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isRunning)
                                .keyboardShortcut(.defaultAction)
                            Button("停止") { model.stop() }
                                .buttonStyle(.bordered)
                                .disabled(!model.isRunning)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }

                    GroupBox("状态") {
                        TransferStatusView(model: model)
                            .padding(.vertical, 6)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320)

            GroupBox {
                HStack(spacing: 10) {
                    Text("日志")
                        .font(.headline)
                    Spacer()
                    Button("清空日志") { model.clearLog() }
                        .disabled(model.logText.isEmpty)
                }
                .padding(.bottom, 6)

                TextEditor(text: $model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(minHeight: 220)
        }
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case upload = "上传"
    case download = "下载"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var tab: MainTab = .upload
    @StateObject private var uploadModel = UploadModel()
    @StateObject private var downloadModel = DownloadModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(MainTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
                if tab == .upload, uploadModel.isRunning {
                    Text("上传中…")
                        .foregroundStyle(.secondary)
                }
                if tab == .download, downloadModel.isRunning {
                    Text("下载中…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()

            Group {
                switch tab {
                case .upload:
                    UploadView(model: uploadModel)
                case .download:
                    DownloadView(model: downloadModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

@main
struct ResumeSMBCopyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}
