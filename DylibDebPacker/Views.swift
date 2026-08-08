import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        TabView {
            SourcesView()
                .tabItem { Label("Sources", systemImage: "tray.and.arrow.down") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "shippingbox") }
            PackageView()
                .tabItem { Label("Package", systemImage: "archivebox") }
        }
        .overlay(alignment: .bottom) {
            StatusBar(text: store.status, busy: store.isBusy)
        }
    }
}

struct StatusBar: View {
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
        .background(.bar)
    }
}

struct SourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var sourceURL = ""

    var body: some View {
        NavigationView {
            List {
                Section("Add Source") {
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
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Sources") {
                    ForEach(store.sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.headline)
                            Text(source.url).font(.caption).foregroundStyle(.secondary)
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

                Section("Packages") {
                    ForEach(store.repoPackages) { package in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(package.name).font(.headline)
                                    Text("\(package.package)  \(package.version)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.download(package)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
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
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.refreshSources()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var importing = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Import .dylib or .deb", systemImage: "doc.badge.plus")
                    }
                }

                Section("Plugins") {
                    ForEach($store.plugins) { $plugin in
                        PluginEditorRow(plugin: $plugin)
                            .onChange(of: plugin) { next in
                                store.update(plugin: next)
                            }
                    }
                    .onDelete(perform: store.deletePlugins)
                }
            }
            .navigationTitle("Library")
            .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    store.importFiles(urls)
                }
            }
        }
    }

    private var importTypes: [UTType] {
        [.item, UTType(filenameExtension: "dylib")!, UTType(filenameExtension: "deb")!]
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

            Picker("Filter", selection: $plugin.filterKind) {
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

    var body: some View {
        NavigationView {
            Form {
                Section("Control") {
                    TextField("Package ID", text: $store.settings.packageID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name", text: $store.settings.name)
                    TextField("Version", text: $store.settings.version)
                    TextField("Architecture", text: $store.settings.architecture)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Maintainer", text: $store.settings.maintainer)
                    Toggle("Rootless /var/jb layout", isOn: $store.settings.rootless)
                }
                .onChange(of: store.settings) { _ in store.save() }

                Section("Dylibs") {
                    ForEach(store.plugins) { plugin in
                        Button {
                            store.toggleSelection(plugin)
                        } label: {
                            HStack {
                                Image(systemName: store.selectedPluginIDs.contains(plugin.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.selectedPluginIDs.contains(plugin.id) ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.displayName)
                                    Text(plugin.filterValue.isEmpty ? "Missing target" : plugin.filterValue)
                                        .font(.caption)
                                        .foregroundStyle(plugin.filterValue.isEmpty ? .red : .secondary)
                                }
                                Spacer()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section {
                    Button {
                        store.buildDeb()
                    } label: {
                        Label("Build deb", systemImage: "hammer")
                    }

                    if let url = store.generatedDebURL {
                        Button {
                            showingShare = true
                        } label: {
                            Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Package")
            .sheet(isPresented: $showingShare) {
                if let url = store.generatedDebURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
