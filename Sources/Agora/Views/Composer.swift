import AgoraCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message box: Enter sends, Shift-Enter adds a line, pasted or dropped files and images become attachments.
struct Composer: View {
    @Binding var text: String
    @Binding var images: [ImageAttachment]
    var placeholder: String
    var isRunning: Bool
    var focusToken: Int = 0
    var onSend: () -> Void
    var onStop: () -> Void
    /// ← / → pressed while the box is empty (Focus switches Bots with them).
    var onArrowWhenEmpty: ((Int) -> Void)? = nil

    @State private var height: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                            AttachmentThumb(image: image) { images.remove(at: i) }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Attach files or images (or drop them here)")
                .padding(.bottom, 3)

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).font(.system(size: 14)).padding(.leading, 5).allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $text, height: $height, focusToken: focusToken, onSubmit: onSend,
                        onArrowWhenEmpty: images.isEmpty ? onArrowWhenEmpty : nil
                    ) { pasted in
                        images.append(contentsOf: pasted)
                    }
                    .frame(height: min(max(height, 22), 180))
                }

                if isRunning && text.isEmpty && images.isEmpty {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.85)))
                            .foregroundStyle(Theme.contentBackground)
                    }
                    .buttonStyle(.plain)
                    .help("Stop the reply")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(canSend ? Theme.accent : Color.secondary.opacity(0.3)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(isRunning ? "Send to steer the Bot while it works" : "Send")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            loadDropped(providers)
            return true
        }
    }

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let a = ImageAttachment.load(url) { images.append(a) }
        }
    }

    func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let a = ImageAttachment.load(url) else { return }
                    Task { @MainActor in images.append(a) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let a = ImageAttachment.from(img) else { return }
                    Task { @MainActor in images.append(a) }
                }
            }
        }
    }
}

extension ImageAttachment {
    /// Any file. Photos in formats Hermes doesn't take as images (HEIC, TIFF, BMP) become PNGs.
    static func load(_ url: URL) -> ImageAttachment? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true, let data = try? Data(contentsOf: url) else { return nil }
        if ["heic", "heif", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased()), let img = NSImage(data: data) {
            return from(img, name: url.deletingPathExtension().lastPathComponent + ".png")
        }
        return ImageAttachment(data: data, filename: url.lastPathComponent)
    }

    static func from(_ image: NSImage, name: String = "pasted.png") -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return ImageAttachment(data: png, filename: name)
    }
}

struct AttachmentThumb: View {
    let image: ImageAttachment
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if image.isImage, let ns = NSImage(data: image.data) {
                Image(nsImage: ns).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                FileChip(name: image.filename, detail: ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))
                    .frame(height: 56)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
    }
}

/// An NSTextView that sends on Enter, inserts a newline on Shift-Enter, and turns pasted images into attachments.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    var onSubmit: () -> Void
    var onArrowWhenEmpty: ((Int) -> Void)?
    var onPasteImages: ([ImageAttachment]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
        tv.onArrowWhenEmpty = { step in
            guard let handler = context.coordinator.parent.onArrowWhenEmpty else { return false }
            handler(step)
            return true
        }
        tv.onPasteImages = { context.coordinator.parent.onPasteImages($0) }
        scroll.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SubmitTextView else { return }
        if tv.string != text { tv.string = text }
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        context.coordinator.recalcHeight(tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocus = 0
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalcHeight(tv)
        }

        func recalcHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            if abs(h - parent.height) > 0.5 {
                let binding = parent.$height
                Task { @MainActor in binding.wrappedValue = h }
            }
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([ImageAttachment]) -> Void)?
    /// Returns true if it used the arrow.
    var onArrowWhenEmpty: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, string.isEmpty, !hasMarkedText(), event.keyCode == 123 || event.keyCode == 124,
            onArrowWhenEmpty?(event.keyCode == 123 ? -1 : 1) == true
        {
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onPasteImages?(urls.compactMap(ImageAttachment.load))
            return
        }
        if pb.string(forType: .string) == nil, let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            onPasteImages?(images.compactMap { ImageAttachment.from($0) })
            return
        }
        super.paste(sender)
    }
}

/// A file's icon and name, for files in the message box and in sent messages.
struct FileChip: View {
    let name: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
