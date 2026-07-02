import Foundation
import Testing
@testable import PalmierPro

private func signature(mean: Float) -> ColorSignature {
    ColorSignature(Scopes(
        lumaMean: mean, lumaBlack: 0.02, lumaWhite: 0.9,
        clipLow: 0.01, clipHigh: 0.02, lumaHistogram: [Float](repeating: 1.0 / 16, count: 16),
        meanRGB: SIMD3(mean, mean, mean), blackRGB: .zero, whiteRGB: SIMD3(1, 1, 1),
        shadowRGB: SIMD3(0.1, 0.1, 0.12), midRGB: SIMD3(0.5, 0.5, 0.5), highRGB: SIMD3(0.9, 0.88, 0.85),
        saturationMean: 0.4, warmCoolBias: 0.05, greenMagentaBias: -0.02,
        hueHistogram: [Float](repeating: 1.0 / 12, count: 12), colorfulPct: 0.6
    ))
}

private func makeProfile(mean: Float = 0.5, moments: [String]? = nil, bpm: Double? = nil) -> StyleProfile {
    StyleProfile(
        version: 1, sourceName: "ref", durationSeconds: 120, analyzedAt: Date(),
        shots: moments.map { $0.enumerated().map { i, m in
            StyleProfile.Shot(startSec: Double(i) * 3, endSec: Double(i + 1) * 3, moment: m, momentConfidence: 0.9)
        } },
        momentSequence: moments,
        cutStats: moments == nil ? nil : StyleProfile.CutStats(
            shotCount: moments!.count, medianShotSec: 3, p25ShotSec: 2, p75ShotSec: 4, shotsPerMinute: 20),
        music: bpm.map { StyleProfile.Music(bpm: $0, confidence: 0.8) },
        cutsOnBeatFraction: bpm == nil ? nil : 0.7,
        color: signature(mean: mean)
    )
}

@Suite("StyleProfile — codable + bridges")
struct StyleProfileTests {

    @Test func codableRoundTrip() throws {
        let original = makeProfile(moments: ["bride_prep", "akad_nikah"], bpm: 100)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StyleProfile.self, from: encoder.encode(original))
        #expect(decoded.momentSequence == ["bride_prep", "akad_nikah"])
        #expect(decoded.music?.bpm == 100)
        #expect(decoded.color == original.color)
    }

    @Test func scopesBridgeRoundTrips() {
        let sig = signature(mean: 0.42)
        let back = ColorSignature(sig.scopes)
        #expect(back == sig)
    }

    @Test func averageBlendsSignatures() {
        let avg = ColorSignature.average([signature(mean: 0.2), signature(mean: 0.6)])
        #expect(abs((avg?.lumaMean ?? 0) - 0.4) < 1e-5)
    }
}

@Suite("StyleGuidance — merge + priority")
struct StyleGuidanceMergeTests {

    @Test func projectOverridesGlobalPerAspect() {
        // Project ref teaches color+tempo only; global teaches structure too.
        let project = makeProfile(mean: 0.3, bpm: 120)
        let global = makeProfile(mean: 0.8, moments: ["venue_establishing", "akad_nikah"], bpm: 90)
        let g = StyleGuidance.merged(project: [project], global: [global], hasBundledPack: true)
        #expect(g.colorSource == "project")
        #expect(abs((g.color?.lumaMean ?? 0) - 0.3) < 1e-5)
        #expect(g.tempoSource == "project")
        #expect(g.bpm == 120)
        #expect(g.structureSource == "global")
        #expect(g.momentSequence == ["venue_establishing", "akad_nikah"])
    }

    @Test func bundledPackIsLastStructureFallback() {
        let g = StyleGuidance.merged(project: [], global: [makeProfile(mean: 0.5)], hasBundledPack: true)
        #expect(g.structureSource == "bundled")
        #expect(g.momentSequence == nil)
        #expect(g.colorSource == "global")
    }

    @Test func multipleRefsPoolStructure() {
        let a = makeProfile(moments: ["venue_establishing", "bride_prep", "akad_nikah"])
        let b = makeProfile(moments: ["venue_establishing", "akad_nikah", "reception"])
        let g = StyleGuidance.merged(project: [a, b], global: [], hasBundledPack: false)
        #expect(g.structureSource == "project")
        #expect(g.momentSequence == nil)
        #expect(g.openingMoments?.first?.moment == "venue_establishing")
        #expect(g.openingMoments?.first?.fraction == 1.0)
        let next = g.commonNext?["venue_establishing"]
        #expect(next?.contains { $0.moment == "bride_prep" } == true)
        #expect(next?.contains { $0.moment == "akad_nikah" } == true)
    }

    @Test func emptyEverythingYieldsNoSources() {
        let g = StyleGuidance.merged(project: [], global: [], hasBundledPack: false)
        #expect(g.colorSource == nil)
        #expect(g.tempoSource == nil)
        #expect(g.structureSource == nil)
    }
}

@Suite("StyleAnalyzer — pure helpers")
struct StyleAnalyzerHelperTests {

    private func shot(_ start: Double, _ end: Double, _ moment: String? = nil) -> StyleProfile.Shot {
        StyleProfile.Shot(startSec: start, endSec: end, moment: moment, momentConfidence: moment == nil ? nil : 0.9)
    }

    @Test func collapsesAdjacentMoments() {
        let shots = [
            shot(0, 3, "bride_prep"), shot(3, 5, "bride_prep"),
            shot(5, 9, "akad_nikah"), shot(9, 12, "bride_prep"),
        ]
        #expect(StyleAnalyzer.collapsedMoments(shots) == ["bride_prep", "akad_nikah", "bride_prep"])
    }

    @Test func cutStatsComputesMedians() {
        let shots = (0..<10).map { shot(Double($0) * 2, Double($0 + 1) * 2) }  // 2s each
        let stats = StyleAnalyzer.cutStats(shots)
        #expect(stats?.shotCount == 10)
        #expect(stats?.medianShotSec == 2.0)
        #expect(stats?.shotsPerMinute == 30.0)
    }

    @Test func cutsOnBeatFractionCountsHits() {
        let beats = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
        // Two cuts on beats, one far off.
        let fraction = StyleAnalyzer.cutsOnBeatFraction(cutTimes: [1.0, 2.05, 3.30], beats: beats, tolerance: 0.15)
        #expect(fraction == 0.67)
    }

    @Test func cutsOnBeatFractionNilWithoutData() {
        #expect(StyleAnalyzer.cutsOnBeatFraction(cutTimes: [], beats: [1]) == nil)
        #expect(StyleAnalyzer.cutsOnBeatFraction(cutTimes: [1], beats: []) == nil)
    }
}

@Suite("Domain color profile — bundled looks + LUTs")
@MainActor
struct DomainColorProfileTests {

    @Test func bundledColorsLoadAndLUTsParse() throws {
        guard let profile = DomainColorStore.load("malay_wedding") else {
            Issue.record("malay_wedding color profile not found in bundle")
            return
        }
        #expect(profile.videosAnalyzed > 0)
        #expect(!profile.looks.isEmpty)
        for look in profile.looks {
            #expect(look.lutFile != nil)
            guard let file = look.lutFile else { continue }
            guard let url = DomainColorStore.lutURL(fileName: file) else {
                Issue.record("LUT missing for look \(look.id): \(file)")
                continue
            }
            #expect(LUTLoader.load(path: url.path) != nil, "LUT \(file) must parse as a valid .cube")
        }
        #expect(profile.look("lut1") != nil)
    }

    @Test func bundledColorFeedsGuidanceAsLastFallback() {
        guard let profile = DomainColorStore.load("malay_wedding") else { return }
        let g = StyleGuidance.merged(
            project: [], global: [], hasBundledPack: false, bundledColor: profile.overall
        )
        #expect(g.colorSource == "bundled")
        #expect(g.color == profile.overall)
    }
}

@Suite("Style tools")
@MainActor
struct StyleToolsTests {

    @Test func setStyleReferenceFlagsAssetAndExcludesFromClassification() async throws {
        let h = ToolHarness()
        let ref = h.addAsset(id: "refVid")
        h.editor.mediaManifest.entries.append(ref.toManifestEntry(projectURL: nil))
        h.addAsset(id: "footage")

        let set = await h.runRaw("set_style_reference", args: ["mediaRef": "refVid"])
        #expect(set.isError == false)
        #expect(ref.isStyleReference)
        #expect(h.editor.mediaManifest.entries.first { $0.id == "refVid" }?.isStyleReference == true)

        // classify_moments must skip the reference.
        let classify = await h.runRaw("classify_moments", args: [:])
        let json = try JSONSerialization.jsonObject(
            with: Data(ToolHarness.textOf(classify).utf8)) as? [String: Any]
        let clips = json?["clips"] as? [[String: Any]]
        #expect(clips?.count == 1)
        #expect(clips?.first?["mediaRef"] as? String == "footage")
    }

    @Test func setStyleReferenceRejectsNonVideo() async {
        let h = ToolHarness()
        h.addAsset(id: "song", type: .audio)
        let result = await h.runRaw("set_style_reference", args: ["mediaRef": "song"])
        #expect(result.isError)
    }

    @Test func removeStyleReferenceUnflags() async {
        let h = ToolHarness()
        let ref = h.addAsset(id: "refVid")
        ref.isStyleReference = true
        let result = await h.runRaw("remove_style_reference", args: ["mediaRef": "refVid"])
        #expect(result.isError == false)
        #expect(!ref.isStyleReference)
    }

    @Test func guidanceFallsBackToBundledStructure() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("get_style_guidance", args: [:])
        #expect(result.isError == false)
        let json = try JSONSerialization.jsonObject(
            with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any]
        // No refs in a fresh harness project → structure comes from the bundled pack.
        if let structure = json?["structure"] as? [String: Any] {
            #expect(structure["source"] as? String == "bundled")
        }
        #expect(json?["references"] != nil)
    }
}
