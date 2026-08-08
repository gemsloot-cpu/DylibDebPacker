import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published var plugins: [PluginFile] = []
    @Published var downloadedDebs: [LocalDebPackage] = []
    @Published var sources: [RepoSource] = []
    @Published var repoPackages: [RepoPackage] = []
    @Published var sourceMessages: [UUID: String] = [:]
    @Published var selectedPluginIDs: Set<UUID> = []
    @Published var settings = PackageSettings()
    @Published var statusVisible = false
    @Published var status = "就绪"
    @Published var generatedDebURL: URL?
    @Published var isBusy = false

    private let fileManager = FileManager.default
    private var statusHideTask: Task<Void, Never>?

    init() {
        load()
    }

    var selectedPlugins: [PluginFile] {
        plugins.filter { selectedPluginIDs.contains($0.id) }
    }

    func documentsURL() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    func pluginsURL() throws -> URL {
        let url = try documentsURL().appendingPathComponent("Plugins", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func debsURL() throws -> URL {
        let url = try documentsURL().appendingPathComponent("Debs", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stateURL() throws -> URL {
        try documentsURL().appendingPathComponent("state.json")
    }

    func load() {
        do {
            let url = try stateURL()
            guard fileManager.fileExists(atPath: url.path) else { return }
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
            plugins = state.plugins
            downloadedDebs = state.downloadedDebs
            sources = state.sources
            settings = state.settings
            selectedPluginIDs = Set(state.plugins.map(\.id))
        } catch {
            showStatus(error.localizedDescription, duration: 4)
        }
    }

    func save() {
        do {
            let state = PersistedState(
                plugins: plugins,
                sources: sources,
                downloadedDebs: downloadedDebs,
                settings: settings
            )
            let data = try JSONEncoder.pretty.encode(state)
            try data.write(to: try stateURL(), options: .atomic)
        } catch {
            showStatus(error.localizedDescription, duration: 4)
        }
    }

    func importFiles(_ urls: [URL]) {
        // 注意：fileImporter 返回的 URL 只在 completion handler 执行期间有效，
        // 系统在回调返回后会清理临时文件，所以必须同步读取内容，
        // 不能放进下面的 Task 里延迟访问（否则会报“无权限/文件不存在”）。
        var items: [(fileName: String, data: Data)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                showStatus("无法读取 \(url.lastPathComponent)", duration: 4)
                return
            }
            items.append((url.lastPathComponent, data))
        }

        Task {
            await runBusy("导入文件") {
                for item in items {
                    try await self.importFileData(item.data, fileName: item.fileName)
                }
                self.save()
                self.showStatus("已导入 \(items.count) 个文件")
            }
        }
    }

    private func importFileData(_ data: Data, fileName: String) async throws {
        let lower = (fileName as NSString).pathExtension.lowercased()
        if lower == "dylib" {
            try addDylibData(data, fileName: fileName, source: "Imported")
        } else if lower == "deb" {
            _ = try addDebData(
                data,
                fileName: fileName,
                packageID: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                version: "",
                source: "Imported"
            )
        } else {
            throw AppError.unsupportedArchive(fileName)
        }
    }

    func extractDylibs(from deb: LocalDebPackage) throws -> [ExtractedDylib] {
        let url = try documentsURL().appendingPathComponent(deb.relativePath)
        return try DebExtractor.extractDylibs(from: Data(contentsOf: url))
    }

    func saveExtractedDylibs(_ items: [ExtractedDylib], from deb: LocalDebPackage) {
        guard !items.isEmpty else { return }
        Task {
            await runBusy("保存插件") {
                for item in items {
                    try self.addDylibData(item.data, fileName: item.name, source: deb.displayName, filter: item.filter)
                }
                self.save()
                self.showStatus("已保存 \(items.count) 个插件")
            }
        }
    }

    func addSource(urlText: String) {
        let count = addSources(from: urlText, refresh: true)
        if count == 0 {
            showStatus(AppError.invalidURL.localizedDescription, duration: 4)
        }
    }

    @discardableResult
    func addSources(from text: String, refresh: Bool) -> Int {
        let urls = RepoURLParser.extractRepoURLs(from: text)
        var added = 0
        for normalized in urls where !sources.contains(where: { $0.url == normalized }) {
            let name = URL(string: normalized)?.host ?? "Source"
            sources.append(RepoSource(name: name, url: normalized))
            added += 1
        }
        if added > 0 {
            save()
            showStatus("已添加 \(added) 个源")
            if refresh { refreshSources() }
        }
        return added
    }

    func removeSource(_ source: RepoSource) {
        sources.removeAll { $0.id == source.id }
        repoPackages.removeAll { $0.sourceID == source.id }
        sourceMessages.removeValue(forKey: source.id)
        save()
    }

    func refreshSources() {
        Task {
            await runBusy("刷新源") {
                var packages: [RepoPackage] = []
                for source in self.sources {
                    do {
                        let found = try await RepoClient.fetchPackages(from: source)
                        packages.append(contentsOf: found)
                        self.sourceMessages[source.id] = found.isEmpty ? "索引为空" : "已读取 \(found.count) 个插件包"
                    } catch {
                        self.sourceMessages[source.id] = error.localizedDescription
                    }
                }
                self.repoPackages = packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.showStatus("已读取 \(packages.count) 个插件包")
            }
        }
    }

    func download(_ package: RepoPackage) {
        Task {
            await runBusy("下载 \(package.name)") {
                guard let url = package.downloadURL else { throw AppError.invalidURL }
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let data = try Data(contentsOf: tempURL)
                _ = try self.addDebData(
                    data,
                    fileName: package.downloadURL?.lastPathComponent ?? "\(package.package).deb",
                    packageID: package.package,
                    version: package.version,
                    source: package.sourceName
                )
                self.save()
                self.showStatus("已保存 \(package.name).deb")
            }
        }
    }

    func deleteDeb(_ deb: LocalDebPackage) {
        if let url = try? documentsURL().appendingPathComponent(deb.relativePath) {
            try? fileManager.removeItem(at: url)
        }
        downloadedDebs.removeAll { $0.id == deb.id }
        save()
    }

    func buildDeb() {
        Task {
            await runBusy("打包 deb") {
                let output = try DebBuilder.build(plugins: self.selectedPlugins, baseURL: try self.documentsURL(), settings: self.settings)
                self.generatedDebURL = output
                self.save()
                self.showStatus("已生成 \(output.lastPathComponent)")
            }
        }
    }

    func toggleSelection(_ plugin: PluginFile) {
        if selectedPluginIDs.contains(plugin.id) {
            selectedPluginIDs.remove(plugin.id)
        } else {
            selectedPluginIDs.insert(plugin.id)
        }
    }

    func selectAllPlugins() {
        selectedPluginIDs = Set(plugins.map(\.id))
    }

    func clearPluginSelection() {
        selectedPluginIDs.removeAll()
    }

    func deletePlugins(at offsets: IndexSet) {
        let ids = Set(offsets.map { plugins[$0].id })
        deletePlugins(ids: ids)
    }

    func deletePlugins(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let deleting = plugins.filter { ids.contains($0.id) }
        for plugin in deleting {
            if let url = try? documentsURL().appendingPathComponent(plugin.relativePath) {
                try? fileManager.removeItem(at: url)
            }
        }
        selectedPluginIDs.subtract(ids)
        plugins.removeAll { ids.contains($0.id) }
        save()
        showStatus("已删除 \(deleting.count) 个插件")
    }

    func update(plugin: PluginFile) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[index] = plugin
        save()
    }

    private func addDebData(
        _ data: Data,
        fileName: String,
        packageID: String,
        version: String,
        source: String
    ) throws -> LocalDebPackage {
        let cleanName = fileName.lowercased().hasSuffix(".deb")
            ? fileName.sanitizedFileComponent
            : "\(fileName).deb".sanitizedFileComponent
        let directory = try debsURL()
        let unique = uniqueFileName(cleanName, in: directory)
        let destination = directory.appendingPathComponent(unique)
        try data.write(to: destination, options: .atomic)

        let deb = LocalDebPackage(
            displayName: URL(fileURLWithPath: unique).deletingPathExtension().lastPathComponent,
            fileName: unique,
            packageID: packageID,
            version: version,
            source: source,
            relativePath: "Debs/\(unique)"
        )
        downloadedDebs.insert(deb, at: 0)
        return deb
    }

    private func addDylibData(
        _ data: Data,
        fileName: String,
        source: String,
        filter: InjectionFilter? = nil
    ) throws {
        let cleanName = fileName.hasSuffix(".dylib") ? fileName.sanitizedFileComponent : "\(fileName).dylib".sanitizedFileComponent
        let unique = uniqueFileName(cleanName, in: try pluginsURL())
        let destination = try pluginsURL().appendingPathComponent(unique)
        try data.write(to: destination, options: .atomic)
        var plugin = PluginFile(displayName: String(unique.dropLast(6)), fileName: unique, relativePath: "Plugins/\(unique)", source: source)
        inferFilter(for: &plugin)
        if let filter, !filter.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plugin.filterKind = filter.kind
            plugin.filterValue = filter.value
        }
        plugins.append(plugin)
        selectedPluginIDs.insert(plugin.id)
    }

    private func uniqueFileName(_ name: String, in directory: URL) -> String {
        var candidate = name
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        var index = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    private func inferFilter(for plugin: inout PluginFile) {
        let key = plugin.debName.lowercased()
        let bundles: [String: String] = [
            "fengchao": "com.fcbox.hiveconsumer",
            "cainiao": "com.cainiao.cnwireless",
            "lolmobile": "com.tencent.ied.app.lolbible",
            "chinamobilecloud": "com.chinamobile.mcloud",
            "chinaradio": "com.cbn.app",
            "qqmusic": "com.tencent.QQMusic",
            "xiaohongshu": "com.xingin.discover",
            "douyin": "com.ss.iphone.ugc.Aweme",
            "wcallrecorder": "com.tencent.xin",
            "weapphelper": "com.tencent.xin"
        ]
        if key == "zhiyuanhui" {
            plugin.filterKind = .executable
            plugin.filterValue = "Volunteer"
            return
        }
        if let value = bundles[key] {
            plugin.filterKind = .bundle
            plugin.filterValue = value
        }
    }

    func showStatus(_ message: String, duration: TimeInterval = 2.8) {
        statusHideTask?.cancel()
        status = message
        statusVisible = true

        guard duration > 0 else { return }
        statusHideTask = Task { [weak self] in
            let nanoseconds = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.statusVisible = false
        }
    }

    private func runBusy(_ label: String, _ work: @escaping () async throws -> Void) async {
        isBusy = true
        showStatus(label, duration: 0)
        do {
            try await work()
        } catch {
            showStatus(error.localizedDescription, duration: 4)
        }
        isBusy = false
    }
}

enum RepoURLParser {
    static func extractRepoURLs(from text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen = Set<String>()
        var result: [String] = []

        for match in matches {
            let raw = nsText.substring(with: match.range)
            if let normalized = normalize(raw), !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(normalized)
            }
        }
        return result
    }

    private static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t,;，；。)]}"))
        guard var components = URLComponents(string: trimmed),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else {
            return nil
        }

        var path = components.path
        if path.hasSuffix("/Packages.gz") {
            path = String(path.dropLast("/Packages.gz".count))
        } else if path.hasSuffix("/Packages") {
            path = String(path.dropLast("/Packages".count))
        } else if path.hasSuffix("/Release") {
            path = String(path.dropLast("/Release".count))
        }
        if path.isEmpty { path = "/" }
        components.path = path.ensureTrailingSlash()
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.ensureTrailingSlash()
    }
}

enum RepoClient {
    static func fetchPackages(from source: RepoSource) async throws -> [RepoPackage] {
        guard let baseURL = URL(string: source.url.ensureTrailingSlash()) else { throw AppError.invalidURL }
        let packageLists = candidatePackagePaths(baseURL: baseURL)
        var sawUnsupportedArchive = false

        for path in packageLists {
            let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
            guard let data = try? await fetch(url), !data.isEmpty else { continue }

            if path.hasSuffix(".xz") || path.hasSuffix(".zst") {
                sawUnsupportedArchive = true
                continue
            }

            let textData: Data
            if path.hasSuffix(".gz") {
                guard let decompressed = try? GzipCodec.decompress(data) else { continue }
                textData = decompressed
            } else if path.hasSuffix(".bz2") {
                guard let decompressed = try? Bzip2Codec.decompress(data) else { continue }
                textData = decompressed
            } else {
                textData = data
            }
            if let text = String(data: textData, encoding: .utf8) {
                let packages = parsePackages(text, source: source)
                if !packages.isEmpty { return packages }
            }
        }

        if sawUnsupportedArchive {
            throw AppError.sourceUnavailable("找到 Packages.xz/zst，但当前版本暂不支持这些压缩格式")
        }
        throw AppError.sourceUnavailable("没有找到可解析的 Packages 索引")
    }

    private static func candidatePackagePaths(baseURL: URL) -> [String] {
        var paths = [
            "Packages",
            "Packages.gz",
            "Packages.bz2",
            "Packages.xz",
            "Packages.zst"
        ]
        let distributions = ["iphoneos-arm64", "stable", "current", "release"]
        let components = ["main", "extras"]
        let architectures = ["iphoneos-arm64", "iphoneos-arm", "arm64", "all"]

        for distribution in distributions {
            for component in components {
                for architecture in architectures {
                    let prefix = "dists/\(distribution)/\(component)/binary-\(architecture)/Packages"
                    paths.append(prefix)
                    paths.append(prefix + ".gz")
                    paths.append(prefix + ".bz2")
                    paths.append(prefix + ".xz")
                    paths.append(prefix + ".zst")
                }
            }
        }
        return paths
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return Data()
        }
        return data
    }

    private static func parsePackages(_ text: String, source: RepoSource) -> [RepoPackage] {
        text.components(separatedBy: "\n\n").compactMap { stanza in
            var fields: [String: String] = [:]
            var currentKey: String?
            for line in stanza.components(separatedBy: .newlines) {
                if line.hasPrefix(" "), let key = currentKey {
                    fields[key, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value
                currentKey = key
            }
            guard let package = fields["Package"], let filename = fields["Filename"] else { return nil }
            return RepoPackage(
                sourceID: source.id,
                sourceName: source.name,
                baseURL: source.url,
                package: package,
                name: fields["Name"] ?? package,
                version: fields["Version"] ?? "",
                architecture: fields["Architecture"] ?? "",
                filename: filename,
                description: fields["Description"] ?? ""
            )
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
