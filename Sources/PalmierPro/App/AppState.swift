import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenOptions {
    var startTutorial = false
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var activeProject: VideoProject?

    private(set) var mcpService: MCPService?

    func startMCPService() {
        guard mcpService == nil else { return }
        guard MCPService.isEnabledPreference else {
            Log.mcp.notice("mcp disabled in settings; not starting")
            return
        }
        let service = MCPService(editorProvider: { [weak self] in
            self?.activeProject?.editorViewModel
        }, openProject: { [weak self] path in
            guard let self else { throw ToolError("App state unavailable") }
            let url = URL(fileURLWithPath: path)
            let project = try await self.openProjectAsync(at: url)
            return project.editorViewModel
        }, exportProject: { [weak self] editor, outputPath, formatStr, resolutionStr in
            guard let self else { throw ToolError("App state unavailable") }
            
            let fmt: ExportFormat
            switch formatStr.lowercased() {
            case "h264": fmt = .h264
            case "h265": fmt = .h265
            case "prores": fmt = .prores
            case "xml": fmt = .xml
            default: throw ToolError("Unknown format '\(formatStr)'. Use h264, h265, prores, or xml.")
            }
            
            let res: ExportResolution
            switch resolutionStr.lowercased() {
            case "720p": res = .r720p
            case "1080p": res = .r1080p
            case "2k": res = .r1440p
            case "4k": res = .r4k
            case "native": res = .native
            default: throw ToolError("Unknown resolution '\(resolutionStr)'. Use 720p, 1080p, 2k, 4k, or native.")
            }
            
            let outputURL = URL(fileURLWithPath: outputPath)
            let resolver = MediaResolver(
                manifest: { editor.mediaManifest },
                projectURL: { editor.projectURL }
            )
            let exportService = ExportService()
            await exportService.export(
                timeline: editor.timeline,
                resolver: resolver,
                format: fmt,
                resolution: res,
                outputURL: outputURL
            )
            if let error = exportService.error {
                throw ToolError(error)
            }
            return ToolExecutor.jsonString(["status": "completed", "outputPath": outputPath, "format": formatStr, "resolution": resolutionStr]) ?? "{}"
        })
        service.start()
        mcpService = service
    }

    func stopMCPService() {
        mcpService?.stop()
        mcpService = nil
    }

    func setMCPEnabled(_ enabled: Bool) {
        MCPService.isEnabledPreference = enabled
        if enabled {
            startMCPService()
        } else {
            stopMCPService()
        }
    }

    func showHome() {
        guard let project = activeProject else {
            HomeWindowController.shared.showWindow(nil)
            return
        }
        let presentHome = {
            if let url = project.fileURL {
                ProjectRegistry.shared.register(url)
            }
            project.windowControllers.forEach { $0.window?.orderOut(nil) }
            if self.activeProject === project {
                self.activeProject = nil
            }
            HomeWindowController.shared.showWindow(nil)
        }
        if project.isDocumentEdited {
            project.autosave(withImplicitCancellability: false) { _ in
                DispatchQueue.main.async {
                    presentHome()
                }
            }
        } else {
            presentHome()
        }
    }

    func showEditor(for project: VideoProject) {
        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
    }

    func revealGeneratedAssetFromNotification(assetId: String?, projectURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let project = notificationTargetProject(assetId: assetId, projectURL: projectURL) else {
            if activeProject == nil {
                HomeWindowController.shared.showWindow(nil)
            }
            return
        }

        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
        project.windowControllers.first?.window?.makeKeyAndOrderFront(nil)

        guard let assetId,
              let asset = project.editorViewModel.mediaAssets.first(where: { $0.id == assetId }) else {
            return
        }

        let editor = project.editorViewModel
        editor.mediaPanelVisible = true
        editor.maximizedPanel = nil
        editor.focusedPanel = .media
        editor.selectMediaAsset(asset)
        editor.mediaPanelRevealAssetId = assetId
    }

    private func notificationTargetProject(assetId: String?, projectURL: URL?) -> VideoProject? {
        let openProjects = NSDocumentController.shared.documents.compactMap { $0 as? VideoProject }
        if let projectURL {
            return openProjects.first { Self.sameFile($0.fileURL, projectURL) }
        }
        if let assetId {
            return openProjects.first { project in
                project.editorViewModel.mediaAssets.contains { $0.id == assetId }
            }
        }
        return activeProject
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    // MARK: - Project lifecycle

    func createNewProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.nameFieldStringValue = Project.defaultProjectName
        panel.directoryURL = Project.storageDirectory
        panel.title = "New Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let doc = VideoProject()
            doc.fileURL = url
            doc.fileType = VideoProject.typeIdentifier
            doc.makeWindowControllers()
            doc.showWindows()
            NSDocumentController.shared.addDocument(doc)
            doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { _ in
                ProjectRegistry.shared.register(url)
            }
        }
    }

    func openProject(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) {
        Task {
            do {
                try await openProjectAsync(at: url, register: register, options: options)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @discardableResult
    func openProjectAsync(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) async throws -> VideoProject {
        let resolved = url.standardizedFileURL
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }
        let doc = try await VideoProject.load(from: resolved)
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }

        doc.makeWindowControllers()
        doc.showWindows()
        NSDocumentController.shared.addDocument(doc)
        if register { ProjectRegistry.shared.register(resolved) }
        apply(options, to: doc.editorViewModel)
        return doc
    }

    private func showExistingProject(at url: URL, register: Bool, options: ProjectOpenOptions) -> VideoProject? {
        if let existing = NSDocumentController.shared.documents
            .compactMap({ $0 as? VideoProject })
            .first(where: { Self.sameFile($0.fileURL, url) }) {
            showEditor(for: existing)
            if register { ProjectRegistry.shared.register(url) }
            apply(options, to: existing.editorViewModel)
            return existing
        }
        return nil
    }

    private func apply(_ options: ProjectOpenOptions, to editor: EditorViewModel) {
        if options.startTutorial {
            DispatchQueue.main.async { editor.tour.start(in: editor) }
        }
    }

    func openSample(slug: String, startTutorial: Bool, onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        let options = ProjectOpenOptions(startTutorial: startTutorial)
        if let cached = SampleProjectService.shared.cachedURL(slug: slug) {
            try await openProjectAsync(at: cached, register: false, options: options)
            return
        }
        let url = try await SampleProjectService.shared.materialize(slug: slug, onProgress: onProgress)
        try await openProjectAsync(at: url, register: false, options: options)
    }

    func openProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            AppState.shared.openProject(at: url)
        }
    }

    private static let projectContentType: UTType = {
        UTType(Project.typeIdentifier)
            ?? UTType(filenameExtension: Project.fileExtension, conformingTo: .package)
            ?? .package
    }()

}
