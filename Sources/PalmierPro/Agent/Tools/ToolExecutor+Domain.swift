import AVFoundation
import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let defaultDomain = "malay_wedding"
    private static let classifyMaxClips = 24
    private static let classifyDefaultClips = 16

    // MARK: - get_reference_guidance

    private static let getReferenceGuidanceAllowedKeys: Set<String> = ["domain", "ceremonyType", "momentType"]

    func getReferenceGuidance(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getReferenceGuidanceAllowedKeys, path: "get_reference_guidance")
        let domain = args.string("domain") ?? Self.defaultDomain
        guard let pack = DomainPackStore.load(domain) else {
            throw ToolError("get_reference_guidance: no domain pack for '\(domain)'. Bundled domains: malay_wedding.")
        }

        var payload: [String: Any] = ["domain": pack.domain]
        if let culture = pack.culture { payload["culture"] = culture }
        if let pacing = pack.typicalPacing { payload["typicalPacing"] = pacing }
        if let audio = pack.audioPatterns { payload["audioPatterns"] = audio }

        if let momentType = args.string("momentType") {
            guard let moment = pack.moment(momentType) else {
                throw ToolError("get_reference_guidance: unknown momentType '\(momentType)'. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            payload["moment"] = Self.momentJSON(momentType, moment)
        } else if let ceremonyType = args.string("ceremonyType") {
            guard let slots = pack.ceremony(ceremonyType) else {
                throw ToolError("get_reference_guidance: unknown ceremonyType '\(ceremonyType)'. Known: \(pack.ceremonyNames.joined(separator: ", ")).")
            }
            payload["ceremonyType"] = ceremonyType.lowercased()
            payload["timeline"] = slots.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Slots are in canonical edit order. Place core slots; include optional when good footage exists; drop filler."
        } else {
            payload["ceremonies"] = pack.ceremonyNames
            payload["moments"] = pack.momentNames.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Pass ceremonyType for an ordered timeline, or momentType for one moment's guidance."
        }

        // How real editors actually sequence shots — available alongside any branch.
        if args.string("momentType") == nil, let ls = pack.learnedSequences {
            payload["learnedSequences"] = Self.learnedJSON(ls)
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("get_reference_guidance: failed to encode result.")
        }
        return .ok(json)
    }

    private static func momentJSON(_ name: String, _ m: DomainPack.Moment) -> [String: Any] {
        var out: [String: Any] = [
            "momentType": name,
            "category": m.category,
            "importance": m.importance,
            "audioPolicy": m.audioPolicy,
            "preferredShots": m.preferredShots,
            "avoidQualities": m.avoidQualities,
            "cues": m.classificationCues,
        ]
        if let dur = m.typicalDurationSec { out["typicalDurationSec"] = dur }
        return out
    }

    private static func learnedJSON(_ ls: DomainPack.LearnedSequences) -> [String: Any] {
        func pairs(_ list: [DomainPack.MomentFraction]) -> [[String: Any]] {
            list.map { ["moment": $0.moment, "fraction": $0.fraction] }
        }
        var out: [String: Any] = [:]
        if let v = ls.videosAnalyzed { out["videosAnalyzed"] = v }
        if let o = ls.openingMoments { out["openingMoments"] = pairs(o) }
        if let n = ls.commonNext { out["commonNext"] = n.mapValues(pairs) }
        if let note = ls.note { out["note"] = note }
        return out
    }

    // MARK: - classify_moments

    private static let classifyMomentsAllowedKeys: Set<String> = ["domain", "ceremonyType", "mediaRefs", "maxClips"]

    func classifyMoments(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.classifyMomentsAllowedKeys, path: "classify_moments")
        let domain = args.string("domain") ?? Self.defaultDomain
        let pack = DomainPackStore.load(domain)

        // Resolve the target video assets.
        let assets: [MediaAsset]
        let explicit = args.stringArray("mediaRefs")
        if !explicit.isEmpty {
            assets = try explicit.map { try asset($0, editor: editor) }
        } else {
            assets = editor.mediaAssets.filter { $0.type == .video }
        }
        let videos = assets.filter { $0.type == .video }
        guard !videos.isEmpty else {
            throw ToolError("classify_moments: no video assets to classify.")
        }
        let limit = min(max(args.int("maxClips") ?? Self.classifyDefaultClips, 1), Self.classifyMaxClips)
        let batch = Array(videos.prefix(limit))

        // Candidate moments the agent should choose from.
        let ceremonyType = args.string("ceremonyType")
        let candidateNames: [String]
        if let pack, let ct = ceremonyType, let slots = pack.ceremony(ct) {
            candidateNames = slots
        } else if let pack {
            candidateNames = pack.momentNames
        } else {
            candidateNames = []
        }
        let candidates: [[String: Any]] = candidateNames.compactMap { name in
            pack?.moment(name).map { ["momentType": name, "cues": $0.classificationCues, "importance": $0.importance] }
        }

        // On-device zero-shot pass: SigLIP predicts each clip's moment locally. Only the
        // clips the local match is unsure about get a frame image sent to the model — the
        // confident ones come back as predictions the agent tags with no vision round-trip.
        let cueList: [(String, String)] = candidates.compactMap {
            guard let n = $0["momentType"] as? String, let c = $0["cues"] as? String else { return nil }
            return (n, c)
        }
        let clipInputs: [(index: Int, url: URL, duration: Double)] = batch.enumerated().compactMap { offset, asset in
            FileManager.default.fileExists(atPath: asset.url.path) ? (offset, asset.url, asset.duration) : nil
        }
        let localByIndex = await Self.zeroShotClassify(clips: clipInputs, cues: cueList)

        // Parallel-sample frames only for the clips that still need the model's eyes.
        let needImage = clipInputs.filter { localByIndex[$0.index]?.confident != true && localByIndex[$0.index]?.jpeg == nil }
        let sampled = await Self.sampleJPEGs(needImage)

        var imageBlocks: [ToolResult.Block] = []
        var clipMeta: [[String: Any]] = []
        for (index, asset) in batch.enumerated() {
            var meta: [String: Any] = [
                "index": index,
                "mediaRef": asset.id,
                "name": asset.name,
                "durationSeconds": (asset.duration * 100).rounded() / 100,
                "filenameSequenceHint": Self.filenameSequenceHint(asset.name),
            ]
            if let tag = asset.momentTag { meta["existingTag"] = tag.momentType }

            let local = localByIndex[index]
            if let local, let best = local.best {
                meta["predictedMomentType"] = best
                meta["confidence"] = (local.confidence * 100).rounded() / 100
                meta["usable"] = local.usable
                if let reason = local.reason { meta["notUsableReason"] = reason }
                meta["alternatives"] = local.alts.prefix(3).map {
                    ["momentType": $0.name, "score": ($0.score * 1000).rounded() / 1000]
                }
            }

            if local?.confident == true {
                meta["frame"] = "not needed (confident local match)"
            } else if let jpeg = local?.jpeg ?? sampled[index] {
                imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
                meta["frame"] = "image #\(imageBlocks.count)"
            } else {
                meta["frame"] = "unavailable"
            }
            clipMeta.append(meta)
        }

        var payload: [String: Any] = [
            "domain": domain,
            "clips": clipMeta,
            "candidateMoments": candidates,
            "instructions": "predictedMomentType is an on-device zero-shot match. usable:false marks throwaway/test footage (see notUsableReason — e.g. floor, ceiling, lens cap, mic test, empty room, feet): do NOT tag or place these on the timeline; skip them. For usable clips whose frame is 'not needed (confident local match)', pass predictedMomentType straight to tag_moments. Clips with an attached 'frame' image are low-confidence — decide those (including whether they're junk) from the image + filenameSequenceHint + cues. Do NOT call inspect_media during bulk classification (it triggers expensive transcription).",
        ]
        if let ceremonyType { payload["ceremonyType"] = ceremonyType.lowercased() }
        if batch.count < videos.count {
            payload["truncated"] = ["shown": batch.count, "total": videos.count, "note": "Pass mediaRefs or raise maxClips to classify the rest."]
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("classify_moments: failed to encode result.")
        }
        return ToolResult(content: imageBlocks + [.text(json)], isError: false)
    }

    // MARK: - tag_moments

    private static let tagMomentsAllowedKeys: Set<String> = ["tags"]
    private static let tagEntryAllowedKeys: Set<String> = ["mediaRef", "momentType", "ceremonyType", "confidence"]

    func tagMoments(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.tagMomentsAllowedKeys, path: "tag_moments")
        guard let rawTags = args["tags"] as? [[String: Any]], !rawTags.isEmpty else {
            throw ToolError("tag_moments: 'tags' must be a non-empty array.")
        }
        let pack = DomainPackStore.load(Self.defaultDomain)

        var applied: [[String: Any]] = []
        for (i, entry) in rawTags.enumerated() {
            try validateUnknownKeys(entry, allowed: Self.tagEntryAllowedKeys, path: "tags[\(i)]")
            let mediaRef = try entry.requireString("mediaRef")
            let momentType = try entry.requireString("momentType")
            if let pack, pack.moment(momentType) == nil {
                throw ToolError("tag_moments: unknown momentType '\(momentType)' in tags[\(i)]. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            let asset = try asset(mediaRef, editor: editor)
            let tag = MomentTag(
                momentType: momentType,
                ceremonyType: entry.string("ceremonyType"),
                confidence: min(max(entry.double("confidence") ?? 1.0, 0), 1),
                source: "agent"
            )
            asset.momentTag = tag
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].momentTag = tag
            }
            applied.append(["mediaRef": asset.id, "momentType": momentType, "confidence": tag.confidence])
        }

        guard let json = Self.jsonString(["tagged": applied.count, "tags": applied]) else {
            throw ToolError("tag_moments: failed to encode result.")
        }
        return .ok(json)
    }

    // MARK: - Helpers

    /// Reports digit groups in a filename so the agent can infer shoot order (e.g. "C0023" -> ["0023"]).
    static func filenameSequenceHint(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        var groups: [String] = []
        var current = ""
        for ch in stem {
            if ch.isNumber { current.append(ch) }
            else if !current.isEmpty { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.isEmpty ? "none" : groups.joined(separator: ",")
    }

    nonisolated private static func sampleMidpointJPEG(url: URL, duration: Double) async -> Data? {
        guard let cg = await sampleMidpointCGImage(url: url, duration: duration) else { return nil }
        return ImageEncoder.encodeJPEG(cg, quality: 0.6)
    }

    // MARK: - On-device zero-shot classification

    /// A clip's local (SigLIP) moment prediction plus a ready frame JPEG for the hybrid path.
    private struct ClipClassification: Sendable {
        let index: Int
        let best: String?
        let confidence: Double
        let confident: Bool
        let usable: Bool
        let reason: String?
        let alts: [(name: String, score: Double)]
        let jpeg: Data?
    }

    // Gate for "confident enough to skip the model": top match must clear a floor and beat
    // the runner-up by a margin. Relative margin is more robust than an absolute cosine.
    nonisolated private static let zeroShotFloor = 0.10
    nonisolated private static let zeroShotMargin = 0.04

    // A clip is "not meaningful" when it matches one of these throwaway descriptions better
    // than any real moment (mic tests, lens caps, floor/ceiling B-roll, empty setup).
    nonisolated private static let junkCues: [(String, String)] = [
        ("floor/ground", "a close-up of the floor, carpet, or ground while walking, shaky and pointing down"),
        ("ceiling", "a shot pointing up at the ceiling or lights, no people"),
        ("black/lens-cap", "a black, dark, or covered frame, lens cap on, nothing visible"),
        ("test/setup", "a microphone or camera test, camera set down on a table, hands adjusting gear"),
        ("empty-room", "an empty room before the event, no people, setup in progress"),
        ("feet/legs", "only someone's feet, legs, or shoes, accidental shot"),
        ("blurry-test", "extremely blurry out-of-focus footage with no discernible subject"),
    ]
    // A clip's best real-moment cosine must clear this to count as meaningful content at all.
    nonisolated private static let meaningfulFloor = 0.06

    /// Classifies each clip against the moment cues on-device. Returns [:] (LLM fallback)
    /// when the search model isn't loaded or there are no cues.
    private static func zeroShotClassify(
        clips: [(index: Int, url: URL, duration: Double)],
        cues: [(String, String)]
    ) async -> [Int: ClipClassification] {
        guard VisualModelLoader.shared.isReady,
              let embedder = VisualModelLoader.shared.embedder,
              !cues.isEmpty, !clips.isEmpty else { return [:] }

        return await Task.detached(priority: .userInitiated) { () -> [Int: ClipClassification] in
            let textVecs: [(String, [Float])] = cues.compactMap { name, cue in
                (try? embedder.encode(text: cue)).map { (name, normalize($0)) }
            }
            guard !textVecs.isEmpty else { return [:] }
            let junkVecs: [(String, [Float])] = junkCues.compactMap { name, cue in
                (try? embedder.encode(text: cue)).map { (name, normalize($0)) }
            }

            let results = await withTaskGroup(of: ClipClassification?.self) { group in
                for clip in clips {
                    group.addTask {
                        guard let cg = await sampleMidpointCGImage(url: clip.url, duration: clip.duration),
                              let raw = try? embedder.encode(image: cg) else { return nil }
                        let v = normalize(raw)
                        let scored = textVecs.map { ($0.0, dot(v, $0.1)) }.sorted { $0.1 > $1.1 }
                        guard let top = scored.first else { return nil }
                        let margin = scored.count >= 2 ? top.1 - scored[1].1 : top.1
                        let confident = top.1 >= zeroShotFloor && margin >= zeroShotMargin

                        // Meaningfulness: does it match a real moment better than any junk cue?
                        let junkScored = junkVecs.map { ($0.0, dot(v, $0.1)) }.sorted { $0.1 > $1.1 }
                        let bestJunk = junkScored.first
                        let usable = top.1 >= meaningfulFloor && top.1 >= (bestJunk?.1 ?? 0)
                        let reason = usable ? nil : (bestJunk.map { "looks like \($0.0)" } ?? "no clear subject")

                        return ClipClassification(
                            index: clip.index,
                            best: top.0,
                            confidence: softmaxTop(scored.map(\.1)),
                            confident: confident,
                            usable: usable,
                            reason: reason,
                            alts: scored.map { (name: $0.0, score: $0.1) },
                            jpeg: ImageEncoder.encodeJPEG(cg, quality: 0.6)
                        )
                    }
                }
                var out: [ClipClassification] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            return Dictionary(uniqueKeysWithValues: results.map { ($0.index, $0) })
        }.value
    }

    nonisolated private static func sampleJPEGs(_ clips: [(index: Int, url: URL, duration: Double)]) async -> [Int: Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for c in clips { group.addTask { (c.index, await sampleMidpointJPEG(url: c.url, duration: c.duration)) } }
            var out: [Int: Data] = [:]
            for await (i, d) in group { if let d { out[i] = d } }
            return out
        }
    }

    nonisolated private static func sampleMidpointCGImage(url: URL, duration: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let mid = CMTime(seconds: max(duration, 0) / 2, preferredTimescale: 600)
        return try? await generator.image(at: mid).image
    }

    nonisolated private static func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    nonisolated private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return Double(s)
    }

    /// Softmax top probability over cosine scores — a rough confidence for display.
    nonisolated private static func softmaxTop(_ xs: [Double]) -> Double {
        guard let mx = xs.max() else { return 0 }
        let exps = xs.map { exp(($0 - mx) * 15) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? (exps.map { $0 / sum }.max() ?? 0) : 0
    }
}
