import AppKit
import SwiftUI

// MARK: - Style gallery (CLI: --render-styles out.png)

enum StyleGallery {
    @MainActor
    static func render(to url: URL) {
        func model(_ style: IndicatorStyle, theme: IndicatorTheme = .fresh, locked: Bool = false) -> PillModel {
            let m = PillModel()
            m.style = style
            m.theme = theme
            m.phase = .recording
            m.locked = locked
            m.startedAt = Date().addingTimeInterval(-74)
            m.meter.freeze(level: 0.62, bands: SIMD3(0.7, 0.55, 0.4))
            return m
        }
        let tiles: [(String, String, PillModel)] = [
            ("1  Glass", "Current. Small capsule, dot and waveform.", model(.halo)),
            ("2  Orb", "A single glowing sphere that breathes with your voice.", model(.orb)),
            ("3  Island", "Black pill hanging under the notch, like iPhone.", model(.island)),
            ("4  Equalizer", "Chunky bars bouncing with bass, mids and highs.", model(.bars)),
            ("5  Glow line", "Just a line of light. No background at all.", model(.line)),
            ("6  Compact bar", "The older bar with live words.", model(.minimal)),
        ]
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Pick a dictation indicator").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.fixed(380), spacing: 18), GridItem(.fixed(380), spacing: 18)], spacing: 18) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: tile.2.style.atTop ? .top : .bottom) {
                            // A blurred "desktop with a window" backdrop, so glass and glow read like they will on screen.
                            LinearGradient(colors: [Color(red: 0.22, green: 0.28, blue: 0.42), Color(red: 0.45, green: 0.33, blue: 0.52), Color(red: 0.9, green: 0.62, blue: 0.5)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.85)).frame(width: 250, height: 120).offset(y: tile.2.style.atTop ? 50 : -30)
                            if tile.2.style.atTop {
                                Rectangle().fill(Color.black.opacity(0.25)).frame(height: 20)
                                Capsule().fill(.black).frame(width: 110, height: 24).offset(y: -4)
                            }
                            Group {
                                switch tile.2.style {
                                case .halo: HaloView(model: tile.2)
                                case .minimal: MinimalPillView(model: tile.2)
                                default: ExpressiveIndicator(model: tile.2, style: tile.2.style)
                                }
                            }
                            .padding(tile.2.style.atTop ? .top : .bottom, tile.2.style.atTop ? 26 : 18)
                        }
                        .frame(width: 380, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(tile.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(tile.1).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(32)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

// MARK: - Preview rendering (CLI: --render-pill out.png)

enum PillPreview {
    /// Renders every indicator state onto a desktop-like backdrop so the design can be reviewed without dictating.
    @MainActor
    static func render(to url: URL) {
        func model(_ phase: PillModel.Phase, mode: DictationMode = .dictation, live: String = "", locked: Bool = false, level: Float = 0.6,
                   theme: IndicatorTheme = .fresh, bands: SIMD3<Float> = SIMD3(0.6, 0.5, 0.4), hint: String? = nil) -> PillModel {
            let m = PillModel()
            m.theme = theme
            m.phase = phase
            m.mode = mode
            m.liveText = live
            m.locked = locked
            m.hint = hint
            m.startedAt = Date().addingTimeInterval(-74)
            m.meter.freeze(level: level, bands: bands)
            return m
        }
        func captioned(_ phase: PillModel.Phase, live: String, final: String? = nil, app: String = "Slack · Casual", available: Bool = true) -> PillModel {
            let m = model(phase, live: live)
            m.captionsOn = true
            m.captionsAvailable = available
            m.appLabel = app
            m.finalText = final
            return m
        }
        let bars: [(String, PillModel)] = [
            ("Listening", model(.recording)),
            ("Hands-free", model(.recording, locked: true, level: 0.35)),
            ("Too quiet", model(.recording, locked: true, level: 0.05, bands: .zero, hint: "Too quiet? Speak up or check your mic")),
            ("Command", model(.recording, mode: .command, level: 0.4)),
            ("Polishing", model(.processing("Polishing…"))),
            ("Done", model(.done("24 words"))),
            ("Error", model(.message("Network is offline — audio saved, retry from the menu", isError: true))),
        ]
        let captions: [(String, PillModel)] = [
            ("Captions · sentences, a correction", captioned(.recording, live: "um so I think we should push the launch to Tuesday no wait Wednesday because the payment fix isn't in")),
            ("Captions · a list", captioned(.recording, live: "OK, so for the trip I need three things first my charger second, my passport and third", app: "Notes · Casual")),
            ("Captions · Prompt mode", captioned(.recording, live: "can you refactor the login page and uh add tests for the token refresh", app: "Cursor · Prompt mode")),
            ("Captions · typed", captioned(.done("3-item list"), live: "", final: "For the trip I need:\n1. My charger\n2. My passport\n3. Sunscreen", app: "Notes · Casual")),
            ("Captions · unavailable", captioned(.recording, live: "", available: false)),
        ]
        let view = HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .center, spacing: 18) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        Text(item.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        HaloView(model: item.1)
                    }
                }
            }
            VStack(alignment: .center, spacing: 22) {
                ForEach(Array(captions.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        Text(item.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        VStack(spacing: 10) {
                            CaptionsCard(model: item.1, accent: IndicatorAccent.color(mode: .dictation, theme: .fresh, error: false))
                            HaloView(model: item.1)
                        }
                    }
                }
            }
        }
        .padding(40)
        .frame(width: 1080)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.22), Color(red: 0.22, green: 0.18, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
