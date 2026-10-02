import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        TabView {
            SourcesView()
                .tabItem { Label("Sources", systemImage: "tray.and.arrow.down") }
            LibraryView()
                .tabItem { Label("Plugins", systemImage: "shippingbox") }
            PackageView()
                .tabItem { Label("Package", systemImage: "archivebox") }
        }
        .tint(.blue)
        .safeAreaInset(edge: .top) {
            if store.isBusy || store.statusVisible {
                StatusToast(text: store.status, busy: store.isBusy)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                }
            }
        }
    }
}

struct StatusToast: View {
    let text: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

struct SourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var sourceURL = ""
    @State private var showingBatchPaste = false
    @State private var batchText = ""
    @State private var packageSearch = ""

    private var filteredPackages: [RepoPackage] {
        let query = packageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.repoPackages }
        return store.repoPackages.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.package.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query) ||
            $0.sourceName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        pasteSourcesFromClipboard()
                    } label: {
                        Label("Import sources from clipboard", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        batchText = UIPasteboard.general.string ?? ""
                        showingBatchPaste = true
                    } label: {
                        Label("Open bulk paste box", systemImage: "text.badge.plus")
                    }
                } footer: {
                    Text("Supports full text, APT lines, and Packages links; automatically detects all http/https source URLs inside.")
                }

                Section("Add manually") {
                    HStack {
                        TextField("https://repo.example.com/", text: $sourceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            store.addSource(urlText: sourceURL)
                            sourceURL = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Added sources") {
                    if store.sources.isEmpty {
                        EmptyHint(title: "No sources yet", subtitle: "Copy multiple jailbreak repo URLs and tap the clipboard button above.")
                    } else {
                        ForEach(store.sources) { source in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).font(.headline)
                                Text(source.url).font(.caption).foregroundStyle(.secondary)
                                Text(store.sourceMessages[source.id] ?? "Waiting to refresh")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.removeSource(source)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Packages in sources") {
                    if store.repoPackages.isEmpty {
                        EmptyHint(title: "No packages yet", subtitle: "Add a source and tap refresh in the top-right.")
                    } else {
                        ForEach(filteredPackages) { package in
                            PackageDownloadRow(package: package) {
                                store.download(package)
                            }
                        }
                    }
                }
            }
            .searchable(
                text: $packageSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search package name, package ID, or source"
            )
            .navigationTitle("Jailbreak Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.refreshSources()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingBatchPaste) {
                BatchPasteView(text: $batchText) {
                    let count = store.addSources(from: batchText, refresh: true)
                    if count > 0 { showingBatchPaste = false }
                }
            }
        }
    }

    private func pasteSourcesFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.showStatus("Clipboard is empty", duration: 4)
            return
        }
        let count = store.addSources(from: text, refresh: true)
        if count == 0 { store.showStatus("No source URLs were detected in the clipboard", duration: 4) }
    }
}

struct BatchPasteView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onImport: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button(action: onImport) {
                    Label("Import detected sources", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Bulk paste sources")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Paste") { text = UIPasteboard.general.string ?? text }
                }
            }
        }
    }
}

struct PackageDownloadRow: View {
    let package: RepoPackage
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name).font(.headline)
                    Text("\(package.package)  \(package.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: action) {
                    Image(systemName: "arrow.down.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
            }
            if !package.description.isEmpty {
                Text(package.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showingDocumentPicker = false
    @State private var selectedDeb: LocalDebPackage?
    @State private var pluginDeleteIDs: Set<UUID> = []

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Import dylib or deb", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("Importing a deb saves the original package first; tap a deb below, then select the dylib to extract.")
                }

                Section("Downloaded debs") {
                    if store.downloadedDebs.isEmpty {
                        EmptyHint(title: "No debs yet", subtitle: "Download from jailbreak sources or import a local deb.")
                    } else {
                        ForEach(store.downloadedDebs) { deb in
                            Button {
                                selectedDeb = deb
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.zipper")
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(deb.displayName)
                                            .font(.headline)
                                        Text([deb.packageID, deb.version].filter { !$0.isEmpty }.joined(separator: "  "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(deb.source)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteDeb(deb)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Plugin library") {
                    if store.plugins.isEmpty {
                        EmptyHint(title: "No plugins yet", subtitle: "Import a dylib/deb first, or download a deb from a source.")
                    } else {
                        HStack {
                            Text("Selected for deletion \(pluginDeleteIDs.count) / \(store.plugins.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                pluginDeleteIDs = Set(store.plugins.map(\.id))
                            } label: {
                                Label("Select all", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                pluginDeleteIDs.removeAll()
                            } label: {
                                Label("Deselect all", systemImage: "circle")
                            }
                            .buttonStyle(.borderless)
                        }

                        Button(role: .destructive) {
                            store.deletePlugins(ids: pluginDeleteIDs)
                            pluginDeleteIDs.removeAll()
                        } label: {
                            Label("Delete selected plugins", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(pluginDeleteIDs.isEmpty)

                        ForEach($store.plugins) { $plugin in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    togglePluginDelete(plugin)
                                } label: {
                                    Image(systemName: pluginDeleteIDs.contains(plugin.id) ? "checkmark.circle.fill" : "circle")
                                        .imageScale(.large)
                                        .foregroundStyle(pluginDeleteIDs.contains(plugin.id) ? .red : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 8)

                                PluginEditorRow(plugin: $plugin)
                                    .onChange(of: plugin) { next in
                                        store.update(plugin: next)
                                    }
                            }
                        }
                        .onDelete(perform: store.deletePlugins)
                    }
                }
            }
            .navigationTitle("Plugin Library")
            .onChange(of: store.plugins) { plugins in
                pluginDeleteIDs.formIntersection(Set(plugins.map(\.id)))
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DylibDocumentPicker { urls in
                    store.importFiles(urls)
                    showingDocumentPicker = false
                }
            }
            .sheet(item: $selectedDeb) { deb in
                DebContentsView(deb: deb)
            }
        }
    }

    private func togglePluginDelete(_ plugin: PluginFile) {
        if pluginDeleteIDs.contains(plugin.id) {
            pluginDeleteIDs.remove(plugin.id)
        } else {
            pluginDeleteIDs.insert(plugin.id)
        }
    }
}

struct DebContentsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let deb: LocalDebPackage

    @State private var dylibs: [ExtractedDylib] = []
    @State private var selectedDylibIDs: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Selected \(selectedDylibIDs.count) / \(dylibs.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            selectedDylibIDs = Set(dylibs.map(\.id))
                        } label: {
                            Label("Select all", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            selectedDylibIDs.removeAll()
                        } label: {
                            Label("Deselect all", systemImage: "circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Dylibs in deb") {
                    if isLoading {
                        ProgressView("Reading deb…")
                    } else if !errorMessage.isEmpty {
                        EmptyHint(title: "Read failed", subtitle: errorMessage)
                    } else if dylibs.isEmpty {
                        EmptyHint(title: "No dylib found", subtitle: "This deb may not be an injection plugin package.")
                    } else {
                        ForEach(dylibs) { dylib in
                            Button {
                                toggleDylib(dylib)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedDylibIDs.contains(dylib.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedDylibIDs.contains(dylib.id) ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(dylib.name)
                                        if let filter = dylib.filter {
                                            Text("\(filter.kind.label): \(filter.value)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("Missing injection target")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(deb.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let selected = dylibs.filter { selectedDylibIDs.contains($0.id) }
                        store.saveExtractedDylibs(selected, from: deb)
                        dismiss()
                    } label: {
                        Label("Save plugins", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selectedDylibIDs.isEmpty || isLoading || !errorMessage.isEmpty)
                }
            }
            .task {
                loadDylibs()
            }
        }
    }

    private func toggleDylib(_ dylib: ExtractedDylib) {
        if selectedDylibIDs.contains(dylib.id) {
            selectedDylibIDs.remove(dylib.id)
        } else {
            selectedDylibIDs.insert(dylib.id)
        }
    }

    private func loadDylibs() {
        do {
            let items = try store.extractDylibs(from: deb)
            dylibs = items
            selectedDylibIDs = Set(items.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct DylibDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [
            UTType(filenameExtension: "dylib")!,
            UTType(filenameExtension: "deb")!
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

struct PluginEditorRow: View {
    @Binding var plugin: PluginFile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.displayName).font(.headline)
                    Text(plugin.source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(plugin.fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Injection target", selection: $plugin.filterKind) {
                ForEach(FilterKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField(plugin.filterKind.label, text: $plugin.filterValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 5)
    }
}

struct PackageView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showingShare = false
    @State private var showAdvanced = false

    var body: some View {
        NavigationView {
            Form {
                Section("Output information") {
                    TextField("Name", text: $store.settings.name)
                    TextField("Version", text: $store.settings.version)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .onChange(of: store.settings) { _ in store.save() }

                Section("Plugin selection") {
                    if store.plugins.isEmpty {
                        EmptyHint(title: "No plugins available to package", subtitle: "Go to the plugin library to import or download a deb for extraction.")
                    } else {
                        HStack {
                            Text("Selected \(store.selectedPlugins.count) / \(store.plugins.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                store.selectAllPlugins()
                            } label: {
                                Label("Select all", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                store.clearPluginSelection()
                            } label: {
                                Label("Deselect all", systemImage: "circle")
                            }
                            .buttonStyle(.borderless)
                        }

                        ForEach(store.plugins) { plugin in
                            Button {
                                store.toggleSelection(plugin)
                            } label: {
                                HStack {
                                    Image(systemName: store.selectedPluginIDs.contains(plugin.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.selectedPluginIDs.contains(plugin.id) ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(plugin.displayName)
                                        Text(plugin.filterValue.isEmpty ? "Missing injection target" : plugin.filterValue)
                                            .font(.caption)
                                            .foregroundStyle(plugin.filterValue.isEmpty ? .red : .secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                        TextField("Package ID", text: $store.settings.packageID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Architecture", text: $store.settings.architecture)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Maintainer", text: $store.settings.maintainer)
                        Toggle("Rootless /var/jb path", isOn: $store.settings.rootless)
                    }
                }
                .onChange(of: store.settings) { _ in store.save() }

                Section {
                    Button {
                        store.buildDeb()
                    } label: {
                        Label("Build deb", systemImage: "hammer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.selectedPlugins.isEmpty)

                    if let url = store.generatedDebURL {
                        Button {
                            showingShare = true
                        } label: {
                            Label("Export \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Package deb")
            .sheet(isPresented: $showingShare) {
                if let url = store.generatedDebURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }
}

struct EmptyHint: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
