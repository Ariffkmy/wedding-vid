import Foundation

extension ToolExecutor {
    func setProjectSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["fps", "width", "height", "letterboxRatio"], path: "set_project_settings")

        let newFPS    = args.int("fps")
        let newWidth  = args.int("width")
        let newHeight = args.int("height")
        let letterbox = args.double("letterboxRatio")

        guard newFPS != nil || newWidth != nil || newHeight != nil || letterbox != nil else {
            throw ToolError("set_project_settings: provide at least one field to change")
        }
        if (newWidth == nil) != (newHeight == nil) {
            throw ToolError("set_project_settings: width and height must be provided together")
        }
        if let fps = newFPS, fps <= 0 {
            throw ToolError("set_project_settings: fps must be positive")
        }
        if let w = newWidth, w <= 0 { throw ToolError("set_project_settings: width must be positive") }
        if let h = newHeight, h <= 0 { throw ToolError("set_project_settings: height must be positive") }

        var changed: [String] = []

        if newFPS != nil || newWidth != nil {
            let fps    = newFPS    ?? editor.timeline.fps
            let width  = newWidth  ?? editor.timeline.width
            let height = newHeight ?? editor.timeline.height
            editor.applyTimelineSettings(fps: fps, width: width, height: height)
            if newFPS != nil    { changed.append("fps → \(fps)") }
            if newWidth != nil  { changed.append("resolution → \(width)×\(height)") }
        }

        if let ratio = letterbox {
            let newRatio: Double? = ratio <= 0 ? nil : ratio
            editor.applyLetterboxRatio(newRatio)
            changed.append(newRatio == nil ? "letterbox removed" : "letterboxRatio → \(ratio)")
        }

        return try jsonResult([
            "changed": changed,
            "fps": editor.timeline.fps,
            "width": editor.timeline.width,
            "height": editor.timeline.height,
            "letterboxRatio": editor.timeline.letterboxRatio as Any,
        ])
    }

    private func jsonResult(_ payload: [String: Any]) throws -> ToolResult {
        guard let json = Self.jsonString(payload) else {
            throw ToolError("set_project_settings: failed to encode result")
        }
        return .ok(json)
    }
}
