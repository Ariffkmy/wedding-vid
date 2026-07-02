import AVFoundation
import Foundation

extension ToolExecutor {
    // MARK: - set_style_reference

    private static let setStyleReferenceAllowedKeys: Set<String> = ["mediaRef", "path", "scope", "vibeNotes"]

    func setStyleReference(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.setStyleReferenceAllowedKeys, path: "set_style_reference")
        let store = StyleReferenceStore.shared
        let vibeNotes = args.string("vibeNotes")

        if let mediaRef = args.string("mediaRef") {
            let asset = try asset(mediaRef, editor: editor)
            guard asset.type == .video else {
                throw ToolError("set_style_reference: '\(mediaRef)' is a \(asset.type.rawValue) asset; style references must be video.")
            }
            if !asset.isStyleReference {
                asset.isStyleReference = true
                if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                    editor.mediaManifest.entries[idx].isStyleReference = true
                }
                store.analyzeAssetIfNeeded(url: asset.url)
            }
            var noteResult = ""
            if let vibeNotes {
                let saved = store.assetProfileURL(url: asset.url)
                    .map { store.updateVibeNotes(profileAt: $0, notes: vibeNotes) } ?? false
                noteResult = saved ? " Vibe notes saved." : " Vibe notes NOT saved (analysis still pending — retry once analyzed)."
            }
            let state = store.assetAnalysisState(url: asset.url)
            return .ok("'\(asset.name)' is now a project style reference (analysis: \(Self.describe(state))).\(noteResult)")
        }

        if let path = args.string("path") {
            guard args.string("scope") != "project" else {
                throw ToolError("set_style_reference: a file path registers a GLOBAL reference; to set a project reference, import the file first and pass its mediaRef.")
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("set_style_reference: no file at \(url.path).")
            }
            let ref = try store.addGlobal(url: url)
            if let vibeNotes {
                _ = store.updateVibeNotes(profileAt: store.globalProfileURL(id: ref.id), notes: vibeNotes)
            }
            return .ok("'\(ref.name)' added as a global style reference (id \(ref.id)); analysis started in the background.")
        }

        // vibeNotes-only update on existing references.
        if let vibeNotes {
            if let ref = store.globalReferences.last,
               store.updateVibeNotes(profileAt: store.globalProfileURL(id: ref.id), notes: vibeNotes) {
                return .ok("Vibe notes saved on global reference '\(ref.name)'.")
            }
            throw ToolError("set_style_reference: pass mediaRef or a global reference's path/id along with vibeNotes.")
        }
        throw ToolError("set_style_reference: provide mediaRef (project scope) or path (global scope).")
    }

    // MARK: - remove_style_reference

    private static let removeStyleReferenceAllowedKeys: Set<String> = ["id", "mediaRef"]

    func removeStyleReference(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeStyleReferenceAllowedKeys, path: "remove_style_reference")
        if let id = args.string("id") {
            guard StyleReferenceStore.shared.globalReferences.contains(where: { $0.id == id }) else {
                throw ToolError("remove_style_reference: no global reference with id '\(id)'.")
            }
            StyleReferenceStore.shared.removeGlobal(id: id)
            return .ok("Global style reference removed.")
        }
        if let mediaRef = args.string("mediaRef") {
            let asset = try asset(mediaRef, editor: editor)
            asset.isStyleReference = false
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].isStyleReference = nil
            }
            return .ok("'\(asset.name)' is no longer a style reference (the asset stays in the library).")
        }
        throw ToolError("remove_style_reference: provide id (global) or mediaRef (project).")
    }

    // MARK: - get_style_guidance

    private static let getStyleGuidanceAllowedKeys: Set<String> = ["includeFrames"]

    func getStyleGuidance(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getStyleGuidanceAllowedKeys, path: "get_style_guidance")
        let store = StyleReferenceStore.shared

        let projectRefs = editor.mediaAssets.filter { $0.isStyleReference && $0.type == .video }
        let projectProfiles = projectRefs.compactMap { store.assetProfile(url: $0.url) }
        let globalProfiles = store.globalReferences.compactMap { store.globalProfile(id: $0.id) }
        let colorProfile = DomainColorStore.load("malay_wedding")
        let guidance = StyleGuidance.merged(
            project: projectProfiles, global: globalProfiles,
            hasBundledPack: DomainPackStore.load("malay_wedding") != nil,
            bundledColor: colorProfile?.overall
        )

        var payload: [String: Any] = [:]
        if let color = guidance.color, let source = guidance.colorSource {
            var json = Self.colorJSON(color, source: source)
            if source == "bundled", let colorProfile {
                json["learnedFrom"] = "\(colorProfile.videosAnalyzed) reference wedding videos"
            }
            payload["color"] = json
        }

        // Grading presets: looks learned from the dataset, each baked into a bundled LUT.
        if let colorProfile {
            let presets: [[String: Any]] = colorProfile.looks.map { look in
                var entry: [String: Any] = [
                    "id": look.id,
                    "name": look.name,
                    "learnedFromVideos": look.videoCount,
                    "targets": [
                        "lumaMean": (Double(look.signature.lumaMean) * 100).rounded() / 100,
                        "saturation": (Double(look.signature.saturationMean) * 100).rounded() / 100,
                        "warmCool": (Double(look.signature.warmCoolBias) * 1000).rounded() / 1000,
                    ],
                ]
                if let file = look.lutFile, let url = DomainColorStore.lutURL(fileName: file) {
                    entry["lutPath"] = url.path
                }
                return entry
            }
            payload["gradingPresets"] = [
                "note": "Looks learned from the reference dataset, each baked into a .cube LUT. Apply with apply_color {lut: {path, strength}} (start strength 0.7-0.9), then verify with inspect_color and fine-tune exposure/temperature toward the targets. Prefer the user's own references (color.source project/global) when present; offer these presets when they have none or ask for options.",
                "presets": presets,
            ]
        }
        if let source = guidance.tempoSource {
            var tempo: [String: Any] = ["source": source]
            if let bpm = guidance.bpm { tempo["bpm"] = (bpm * 10).rounded() / 10 }
            if let f = guidance.cutsOnBeatFraction { tempo["cutsOnBeatFraction"] = f }
            if let c = guidance.cutStats {
                tempo["cutStats"] = [
                    "medianShotSec": c.medianShotSec, "p25ShotSec": c.p25ShotSec,
                    "p75ShotSec": c.p75ShotSec, "shotsPerMinute": c.shotsPerMinute,
                ]
            }
            payload["tempo"] = tempo
        }
        if let source = guidance.structureSource {
            var structure: [String: Any] = ["source": source]
            if let seq = guidance.momentSequence {
                structure["momentSequence"] = seq
            }
            if let opening = guidance.openingMoments {
                structure["openingMoments"] = opening.map { ["moment": $0.moment, "fraction": $0.fraction] }
            }
            if let next = guidance.commonNext {
                structure["commonNext"] = next.mapValues { $0.map { ["moment": $0.moment, "fraction": $0.fraction] } }
            }
            if source == "bundled" {
                structure["note"] = "No reference provides structure — use get_reference_guidance (bundled pack) for ordering."
            }
            payload["structure"] = structure
        }
        if !guidance.vibeNotes.isEmpty { payload["vibeNotes"] = guidance.vibeNotes }

        payload["references"] = [
            "project": projectRefs.map {
                ["mediaRef": $0.id, "name": $0.name, "analysis": Self.describe(store.assetAnalysisState(url: $0.url))]
            },
            "global": store.globalReferences.map {
                ["id": $0.id, "name": $0.name, "analysis": Self.describe(store.states[$0.id])]
            },
        ]
        payload["instructions"] = "Per-aspect priority: project references override global; bundled pack is the last fallback (each aspect names its source). Apply color with color_match_from_reference {useStyleReference: true}. Pace cuts to cutStats/bpm via analyze_audio_beats on the chosen music. When structure.source is project/global, follow ITS moment order instead of the bundled ceremony order. Never place style-reference assets on the timeline. If a reference's analysis is pending, mention it and proceed with what's available."

        // Representative frames so the model can read the vibe (then store it via
        // set_style_reference vibeNotes).
        var blocks: [ToolResult.Block] = []
        if args["includeFrames"] as? Bool == true {
            var frameSources: [(URL, Double)] = []
            if let first = projectRefs.first { frameSources.append((first.url, first.duration)) }
            if let ref = store.globalReferences.first, let url = store.videoURL(globalId: ref.id) {
                frameSources.append((url, 0))
            }
            for (url, knownDuration) in frameSources.prefix(2) {
                let duration = knownDuration > 0 ? knownDuration : (await Self.mediaDuration(url) ?? 0)
                for position in [0.15, 0.5, 0.85] where duration > 0 {
                    if let cg = await MomentClassifier.sampleImage(url: url, duration: duration, position: position),
                       let jpeg = ImageEncoder.encodeJPEG(cg, quality: 0.6) {
                        blocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
                    }
                }
            }
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("get_style_guidance: failed to encode result.")
        }
        return ToolResult(content: blocks + [.text(json)], isError: false)
    }

    /// Merged style scopes for color matching, or nil when no reference has one.
    func styleReferenceScopes(_ editor: EditorViewModel) -> Scopes? {
        let store = StyleReferenceStore.shared
        let project = editor.mediaAssets
            .filter { $0.isStyleReference && $0.type == .video }
            .compactMap { store.assetProfile(url: $0.url) }
        let global = store.globalReferences.compactMap { store.globalProfile(id: $0.id) }
        let guidance = StyleGuidance.merged(
            project: project, global: global, hasBundledPack: false,
            bundledColor: DomainColorStore.load("malay_wedding")?.overall
        )
        return guidance.color?.scopes
    }

    // MARK: - Helpers

    private static func describe(_ state: StyleReferenceStore.AnalysisState?) -> String {
        switch state {
        case .pending: "pending"
        case .analyzing: "analyzing"
        case .done: "done"
        case .failed(let reason): "failed: \(reason)"
        case nil: "pending"
        }
    }

    private static func colorJSON(_ c: ColorSignature, source: String) -> [String: Any] {
        func r3(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
        func rgb(_ v: [Float]) -> [Double] { v.map(r3) }
        return [
            "source": source,
            "luma": ["black": r3(c.lumaBlack), "white": r3(c.lumaWhite), "mean": r3(c.lumaMean)],
            "meanRGB": rgb(c.meanRGB),
            "zones": ["shadows": rgb(c.shadowRGB), "mids": rgb(c.midRGB), "highs": rgb(c.highRGB)],
            "saturation": r3(c.saturationMean),
            "balance": ["warmCool": r3(c.warmCoolBias), "greenMagenta": r3(c.greenMagentaBias)],
            "note": "Targets from the reference grade. Apply with color_match_from_reference {useStyleReference: true}; fine-tune with apply_color + inspect_color.",
        ]
    }

    nonisolated private static func mediaDuration(_ url: URL) async -> Double? {
        try? await AVURLAsset(url: url).load(.duration).seconds
    }
}
