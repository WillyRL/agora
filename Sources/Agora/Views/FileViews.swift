import AgoraCore
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A Bot message: its text, with any files it hands over (`MEDIA:` / `::preview`) shown in place.
struct MessageContent: View {
    let text: String
    let conversation: Conversation

    var body: some View {
        let parts = MessagePart.split(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let t): MarkdownView(text: t)
                case .file(let file): FileAttachmentView(file: file, conversation: conversation)
                }
            }
        }
    }
}

struct FileAttachmentView: View {
    let file: FileAttachment
    let conversation: Conversation

    var body: some View {
        switch file.kind {
        case .image: ChatImageView(image: .hostPath(file.path), conversation: conversation)
        case .html where file.inline: HTMLPreview(file: file, conversation: conversation)
        default: FileCard(file: file, conversation: conversation)
        }
    }
}

// MARK: File card (PowerPoint, PDF, spreadsheets, anything)

/// A file on the Hermes host: open it in its app, Quick Look it, or save a copy.
struct FileCard: View {
    @Environment(AgoraCore.self) private var core
    let file: FileAttachment
    let conversation: Conversation
    @State private var quickLook: URL?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(error ?? kindName).font(.system(size: 11)).foregroundStyle(error == nil ? Color.secondary : Color.red).lineLimit(1)
            }
            Spacer(minLength: 12)
            if busy { ProgressView().controlSize(.small) }
            Button("Open") { run { NSWorkspace.shared.open($0) } }
            Button {
                run { quickLook = $0 }
            } label: {
                Image(systemName: "eye")
            }
            .help("Quick Look")
            Button {
                run(save)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save a Copy…")
        }
        .controlSize(.small)
        .disabled(busy)
        .padding(10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .contextMenu {
            Button("Open") { run { NSWorkspace.shared.open($0) } }
            Button("Quick Look") { run { quickLook = $0 } }
            Button("Save a Copy…") { run(save) }
            Button("Show in Finder") { run { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
            Divider()
            Button("Copy Path on Hermes") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
        .quickLookPreview($quickLook)
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: file.fileExtension) ?? .data)
    }

    var kindName: String {
        UTType(filenameExtension: file.fileExtension)?.localizedDescription?.capitalizedFirst ?? "File"
    }

    /// Downloads a fresh copy, then does `action` with it.
    func run(_ action: @escaping (URL) -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                action(try await core.localCopy(of: file.path, in: conversation))
            } catch {
                self.error = "Couldn't get the file: \(error.localizedDescription)"
            }
        }
    }

    func save(_ copy: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: copy, to: target)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Live HTML (`::preview`)

/// An HTML page the Bot made, shown live in the message: scripts run, links open in the browser,
/// and it sizes itself to its content. It gets the app's colors as CSS variables first, like
/// Hermes's own app, so a widget that uses them matches light and dark mode.
struct HTMLPreview: View {
    @Environment(AgoraCore.self) private var core
    @Environment(\.colorScheme) private var scheme
    let file: FileAttachment
    let conversation: Conversation
    @State private var html: String?
    @State private var error: String?
    @State private var height: CGFloat = 280
    @State private var reloads = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let html {
                    HTMLWebView(html: html, theme: HTMLTheme(dark: scheme == .dark), height: $height) { prompt in
                        Task { await core.send(prompt, to: conversation) }
                    }
                    .frame(height: height)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Label(file.name, systemImage: "doc.richtext").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Open in Browser") { withCopy { NSWorkspace.shared.open($0) } }
                Button("Reload") { reloads += 1 }
                Button("Save a Copy…") { withCopy(save) }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .task(id: "\(file.path)|\(reloads)") { await load() }
    }

    func load() async {
        do {
            let data = try await core.fileData(file.path, in: conversation)
            html = String(decoding: data, as: UTF8.self)
            error = nil
        } catch {
            if html == nil { self.error = "Couldn't load \(file.name): \(error.localizedDescription)" }
        }
    }

    func withCopy(_ action: @escaping (URL) -> Void) {
        Task {
            if let url = try? await core.localCopy(of: file.path, in: conversation) { action(url) }
        }
    }

    func save(_ copy: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: copy, to: target)
    }
}

/// The app's colors under the names Hermes widgets expect.
struct HTMLTheme: Equatable {
    var dark: Bool

    var css: String {
        let v =
            dark
            ? ["foreground": "#e8e8ed", "muted-foreground": "#9a9aa3", "accent": "#a78bfa", "border": "rgba(255,255,255,0.12)", "card": "rgba(255,255,255,0.04)"]
            : ["foreground": "#1d1d1f", "muted-foreground": "#6e6e73", "accent": "#7c3aed", "border": "rgba(0,0,0,0.10)", "card": "rgba(0,0,0,0.03)"]
        let vars = v.sorted { $0.key < $1.key }.map { "--\($0.key):\($0.value);" }.joined()
        return ":root{\(vars)color-scheme:\(dark ? "dark" : "light");}"
            + "html,body{margin:0;padding:0;background:transparent;color:var(--foreground);font:13px -apple-system,BlinkMacSystemFont,sans-serif;}"
    }
}

struct HTMLWebView: NSViewRepresentable {
    let html: String
    let theme: HTMLTheme
    @Binding var height: CGFloat
    let send: (String) -> Void

    static let minHeight: CGFloat = 120
    static let maxHeight: CGFloat = 1200

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let content = config.userContentController
        content.add(context.coordinator, name: "agoraSize")
        content.add(context.coordinator, name: "agoraSend")
        content.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(into: view)
        return view
    }

    func updateNSView(_ view: PassthroughWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: view)
    }

    static func dismantleNSView(_ view: PassthroughWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// The theme goes first so the page's own styles win; a full page keeps its own design.
    static func document(_ html: String, theme: HTMLTheme) -> String {
        let style = "<style id=\"agora-theme\">\(theme.css)</style>"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: style, at: head.upperBound)
            return out
        }
        return style + html
    }

    /// Reports the content's height, and gives widgets `hermes.send(prompt)` / `data-hermes-send`.
    static let bridgeScript = """
        (function(){
          function report(){
            var b=document.body, h=Math.max(b?b.scrollHeight:0, document.documentElement.scrollHeight);
            window.webkit.messageHandlers.agoraSize.postMessage(h);
          }
          // The frame grows with the page, so the page never scrolls inside it (no stray scrollbar).
          var s=document.createElement('style'); s.textContent='html,body{overflow:hidden!important}';
          document.documentElement.appendChild(s);
          new ResizeObserver(report).observe(document.documentElement);
          addEventListener('load', report); report();
          var last=0;
          function send(p){
            if(typeof p!=='string'||!p.trim()) return Promise.resolve({ok:false,error:'invalid'});
            if(p.length>500) return Promise.resolve({ok:false,error:'too_long',maxLength:500});
            var now=Date.now(); if(now-last<1000) return Promise.resolve({ok:false,error:'throttled',retryAfterMs:1000-(now-last)});
            last=now; window.webkit.messageHandlers.agoraSend.postMessage(p); return Promise.resolve({ok:true});
          }
          window.hermes=Object.assign(window.hermes||{}, {send:send});
          document.addEventListener('click', function(e){
            var el=e.target.closest&&e.target.closest('[data-hermes-send]');
            if(el){ e.preventDefault(); send(el.getAttribute('data-hermes-send')); }
          }, true);
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: HTMLWebView
        var loaded: String?

        init(_ parent: HTMLWebView) { self.parent = parent }

        func load(into view: WKWebView) {
            let doc = HTMLWebView.document(parent.html, theme: parent.theme)
            guard doc != loaded else { return }
            loaded = doc
            view.loadHTMLString(doc, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "agoraSize":
                guard let h = (message.body as? NSNumber).map({ CGFloat(truncating: $0) }) else { return }
                let clamped = min(HTMLWebView.maxHeight, max(HTMLWebView.minHeight, h))
                if abs(clamped - parent.height) > 4 { DispatchQueue.main.async { self.parent.height = clamped } }
            case "agoraSend":
                if let prompt = message.body as? String { parent.send(prompt) }
            default: break
            }
        }

        /// Links leave the chat: they open in the browser instead of replacing the widget.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme != "about" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// A web view that lets the chat scroll past it: the page is sized to its content, so wheel
/// events belong to the chat, not the page.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
