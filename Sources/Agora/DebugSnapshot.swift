import AppKit
import SwiftUI
import WebKit

/// Development aid: with `AGORA_SNAPSHOT=/path/prefix` set, Agora walks through the screens named in
/// `AGORA_SNAPSHOT_STEPS` (e.g. `today,bot:coder,allbots,edit:coder,routines:coder,focus:coder,quickask`) and saves
/// a PNG of each, so UI work can be checked without screen-recording permission. Read-only: it never sends.
@MainActor
enum DebugSnapshot {
    static var prefix: String? { ProcessInfo.processInfo.environment["AGORA_SNAPSHOT"] }

    static func runScript(model: AppModel) async {
        let steps = (ProcessInfo.processInfo.environment["AGORA_SNAPSHOT_STEPS"] ?? "today").split(separator: ",").map(String.init)
        try? await Task.sleep(for: .seconds(1.5))
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            model.quickAsk.close()
            switch parts[0] {
            case "today": model.destination = .today
            case "bot": model.destination = .bot(arg)
            case "allbots": model.destination = .allBots
            case "edit": model.destination = .editBot(arg)
            case "new": model.destination = .newBot
            case "routines":
                model.destination = .bot(arg)
                model.showRoutines = true
            case "setup":
                // `setup:remote` opens it on "On another machine" (the tailnet list).
                model.setupStartsRemote = arg == "remote"
                model.showSetup = true
                if arg == "remote" { try? await Task.sleep(for: .seconds(5)) }  // let the tailnet scan finish
            case "side":
                // The first Side Chat of a Bot (opening one only reads it).
                await model.core.loadSideChats(for: arg)
                if let first = model.core.sideChats[arg]?.first { model.destination = .sideChat(bot: arg, session: first.id) }
            case "focus":
                // `focus:<bot>` opens that Bot in Focus; `focus:next` moves one Bot along.
                if arg == "next" { model.switchBot(1) } else {
                    model.destination = .bot(arg)
                    model.setFocus(true)
                }
            case "quickask": model.quickAsk.open()
            case "mcpadd":
                // The Add MCP Server form, typed into: `mcpadd:<name>` (shows a trailing space stays visible).
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Add MCP"
                window.contentView = NSHostingView(rootView: AddMCPServerSheet(editing: nil, existing: [], done: { _ in }, initialName: arg).environment(model.core))
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(2))
                capture("mcpadd", in: window)
                window.orderOut(nil)
                continue
            case "height":
                // `height:<points>`: makes the main window taller to see a whole page.
                if let w = NSApp.windows.first(where: { $0.title == "Agora" }), let h = Double(arg) {
                    var f = w.frame
                    f.origin.y -= h - f.height
                    f.size.height = h
                    w.setFrame(f, display: true)
                }
                continue
            case "size":
                // `size:<width>x<height>`: an exact window size (README screenshots).
                let wh = arg.split(separator: "x").compactMap { Double($0) }
                if let w = NSApp.windows.first(where: { $0.title == "Agora" }), wh.count == 2 {
                    w.setFrame(NSRect(x: 80, y: 80, width: wh[0], height: wh[1]), display: true)
                }
                continue
            case "appearance":
                // Applies without saving, so the user's choice is untouched.
                (AppearanceChoice(rawValue: arg) ?? .system).apply()
                continue
            case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "scrollup":
                // Scrolls the biggest scroll view (the chat, or a page) up by `arg` points; negative scrolls down.
                scrollUp(by: CGFloat(Double(arg) ?? 600))
            case "mcp":
                // Settings → MCP Servers, in a window of its own. `mcp:<server>` also runs Test Connection on it (read-only).
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "MCP Servers"
                window.contentView = NSHostingView(rootView: MCPSettings(autoTest: arg.isEmpty ? nil : arg).environment(model.core).environment(model))
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(arg.isEmpty ? 4 : 12))
                capture("mcp", in: window)
                window.orderOut(nil)
                continue
            default: break
            }
            try? await Task.sleep(for: .seconds(2.5))
            await snapWebViews()
            capture(step.replacingOccurrences(of: ":", with: "-"))
            if parts[0] == "routines" { model.showRoutines = false }
            if parts[0] == "setup" { model.showSetup = false }
        }
        NSApp.terminate(nil)
    }

    static var webShots: [(NSImage, NSRect)] = []

    static func mainView() -> NSView? {
        let window = NSApp.windows.first { $0.isVisible && $0.title == "Agora" } ?? NSApp.windows.first { $0.isVisible }
        return window?.contentView?.superview ?? window?.contentView
    }

    static func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }

    static func snapWebViews() async {
        guard let root = mainView() else { return }
        for web in allSubviews(root).compactMap({ $0 as? WKWebView }) where web.window != nil && !web.isHiddenOrHasHiddenAncestor {
            let visible = web.visibleRect
            guard visible.width > 1, visible.height > 1 else { continue }
            let config = WKSnapshotConfiguration()
            config.rect = visible
            if let image = try? await web.takeSnapshot(configuration: config) {
                webShots.append((image, web.convert(visible, to: root)))
            }
        }
    }

    static func scrollUp(by points: CGFloat) {
        guard let root = mainView() else { return }
        let scrolls = allSubviews(root).compactMap { $0 as? NSScrollView }.filter { !($0.superview is WKWebView) }
        guard let chat = scrolls.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }  // the page, not a text box in it
        let clip = chat.contentView
        let maxY = max(0, (chat.documentView?.frame.height ?? 0) - clip.bounds.height)
        let y = min(maxY, max(0, clip.isFlipped ? clip.bounds.origin.y - points : clip.bounds.origin.y + points))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        chat.reflectScrolledClipView(clip)
    }

    static func capture(_ name: String, in chosen: NSWindow? = nil) {
        guard let prefix else { return }
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = chosen ?? windows.first(where: { $0 is QuickAskPanel }) ?? windows.first(where: { $0.title == "Agora" }) ?? windows.first,
            let view = window.contentView?.superview ?? window.contentView
        else { return }
        let bounds = view.bounds
        let scale = window.backingScaleFactor
        // Render the layer tree (what's on screen), falling back to AppKit drawing.
        if ProcessInfo.processInfo.environment["AGORA_SNAPSHOT_DRAW"] == nil, let layer = view.layer,
            let ctx = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            ctx.scaleBy(x: scale, y: scale)
            if view.isFlipped {
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            // Web views draw out of process, so the layer tree has them blank: paint their snapshots in.
            for (image, rect) in webShots {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let r = rect
                ctx.saveGState()
                if view.isFlipped {
                    ctx.translateBy(x: r.minX, y: r.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
                } else {
                    ctx.draw(cg, in: r)
                }
                ctx.restoreGState()
            }
            webShots = []
            if let image = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
                    return
                }
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }
}
