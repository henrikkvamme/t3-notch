import AppKit
import SwiftUI

/// The island's message field. A selection sits in the text as a chip, at the place where you
/// stopped typing, as in T3's own field. ⌫ removes a chip, a click on it opens its comment.
///
/// The model stays plain: `ui.draft` is the text without chips, and each clip in `ui.clips`
/// has its `offset` in that text. So the draft still goes to T3's field as it is.
struct DraftField: NSViewRepresentable {
    let ui: OverlayUIState
    // Read in the parent's body, so a change brings an update here.
    let draft: String
    let clips: [Clip]
    let labels: [String]
    let editing: UUID?
    let landing: Bool
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static let maxLines = 6
    static var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }
    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.white]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let text = DraftTextView(frame: NSRect(x: 0, y: 0, width: 300, height: Self.lineHeight))
        text.delegate = context.coordinator
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = Self.font
        text.textColor = .white
        text.insertionPointColor = .white
        text.typingAttributes = Self.attributes
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: Self.lineHeight)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.setAccessibilityLabel("Message")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = text
        context.coordinator.text = text
        let ui = ui
        // A click on a chip opens its picture and comment, and a second click closes them.
        text.onChipClick = { id in
            withAnimation(Motion.content) { ui.editingClip = ui.editingClip == id ? nil : id }
            ui.onRequestFocus?()
        }
        // The pointer on a chip shows its picture above the field.
        text.onChipHover = { id in
            guard ui.hoveredClip != id else { return }
            withAnimation(Motion.snappy) { ui.hoveredClip = id }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.modelChanged()
    }

    /// One to six lines high, as wide as offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let text = context.coordinator.text, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let width = max(proposal.width ?? scroll.frame.width, 40)
        if abs(text.frame.width - width) > 0.5 { text.setFrameSize(NSSize(width: width, height: text.frame.height)) }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        let line = Self.lineHeight
        return CGSize(width: width, height: min(max(used, line), line * CGFloat(Self.maxLines)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftField
        weak var text: DraftTextView?
        /// Each selection that was in the field, so an undo can bring a removed one back.
        private var known: [UUID: Clip] = [:]
        private var applying = false

        init(_ parent: DraftField) { self.parent = parent }

        // MARK: The model changed

        /// What the field has now: the text without chips, and each chip's place in it.
        private func fieldState() -> (plain: String, chips: [(id: UUID, offset: Int, label: String, editing: Bool)]) {
            guard let storage = text?.textStorage else { return ("", []) }
            let plain = NSMutableString()
            var chips: [(UUID, Int, String, Bool)] = []
            let whole = storage.string as NSString
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let chip = value as? ChipAttachment {
                    chips.append((chip.clipID, plain.length, chip.label, chip.editing))
                } else {
                    plain.append(whole.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: ""))
                }
            }
            return (plain as String, chips)
        }

        func modelChanged() {
            guard !applying, let text, let storage = text.textStorage else { return }
            let ui = parent.ui
            for clip in ui.clips { known[clip.id] = clip }
            let now = fieldState()
            var clips = ui.clips
            let labels = clips.map { $0.comment.isEmpty ? $0.label : $0.comment }
            let same = now.plain == ui.draft
                && now.chips.map(\.id) == clips.map(\.id)
                && zip(now.chips, clips).allSatisfy { $0.offset == $1.offset }
                && now.chips.map(\.label) == labels
                && now.chips.allSatisfy { $0.editing == (ui.editingClip == $0.id) }
            if !same {
                let old = now.plain as NSString, new = ui.draft as NSString
                // The text changed from outside (T3's field, a message that came back): a chip
                // before the change stays, a chip after it moves with the text.
                if old != new {
                    var prefix = 0
                    while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
                    var suffix = 0
                    while suffix < min(old.length, new.length) - prefix,
                          old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
                    // Only a chip that is in the field: a clip that comes with the text has its place in it.
                    for i in clips.indices {
                        guard let at = now.chips.first(where: { $0.id == clips[i].id })?.offset else { continue }
                        clips[i].offset = at <= prefix ? at
                            : at >= old.length - suffix ? at + new.length - old.length : new.length - suffix
                    }
                }
                // A new selection goes where the caret is.
                var caret = plainOffset(of: text.selectedRange().location)
                if old != new { caret = new.length }
                var landed: UUID?
                for i in clips.indices where clips[i].offset == nil {
                    clips[i].offset = caret
                    landed = clips[i].id
                }
                for i in clips.indices { clips[i].offset = min(max(clips[i].offset ?? 0, 0), new.length) }
                // Chips in the order of the text. A stable sort: chips at one place keep their order.
                let order = clips.enumerated().sorted { ($0.element.offset!, $0.offset) < ($1.element.offset!, $1.offset) }.map(\.element)
                let built = NSMutableAttributedString()
                var at = 0, caretAfter: Int?
                for clip in order {
                    let offset = clip.offset!
                    built.append(NSAttributedString(string: new.substring(with: NSRange(location: at, length: offset - at)), attributes: DraftField.attributes))
                    built.append(chip(for: clip, editing: ui.editingClip == clip.id))
                    if clip.id == landed { caretAfter = built.length }
                    at = offset
                }
                built.append(NSAttributedString(string: new.substring(from: at), attributes: DraftField.attributes))
                let keep = old == new && landed == nil ? text.selectedRange() : nil
                applying = true
                storage.setAttributedString(built)
                text.typingAttributes = DraftField.attributes
                text.undoManager?.removeAllActions()
                let end = NSRange(location: caretAfter ?? built.length, length: 0)
                text.setSelectedRange(keep.map { NSRange(location: min($0.location, built.length), length: 0) } ?? end)
                applying = false
                text.scrollRangeToVisible(text.selectedRange())
                text.enclosingScrollView?.invalidateIntrinsicContentSize()
                if order.map(\.id) != ui.clips.map(\.id) || zip(order, ui.clips).contains(where: { $0.offset != $1.offset }) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.applying else { return }
                        // Only when nothing else changed the list in between.
                        guard Set(ui.clips.map(\.id)) == Set(order.map(\.id)) else { return }
                        self.applying = true
                        ui.clips = order.map { placed in
                            var clip = ui.clips.first { $0.id == placed.id } ?? placed
                            clip.offset = placed.offset
                            return clip
                        }
                        self.applying = false
                    }
                }
            }
            if parent.landing { reportLandingSlot() }
        }

        /// A place in the field's text, chips included, as a place in the text without them.
        private func plainOffset(of location: Int) -> Int {
            guard let storage = text?.textStorage else { return 0 }
            var chips = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: min(location, storage.length))) { value, range, _ in
                if value != nil { chips += range.length }
            }
            return max(min(location, storage.length) - chips, 0)
        }

        private func chip(for clip: Clip, editing: Bool) -> NSAttributedString {
            let label = clip.comment.isEmpty ? clip.label : clip.comment
            let chip = ChipAttachment(clipID: clip.id, label: label, editing: editing, thumbnail: clip.thumbnail,
                                      strong: !clip.comment.isEmpty)
            let s = NSMutableAttributedString(attachment: chip)
            s.addAttributes(DraftField.attributes, range: NSRange(location: 0, length: s.length))
            return s
        }

        /// Where a selection that is flying in will sit: at the caret. In the window, top-left origin.
        private func reportLandingSlot() {
            guard let text, let layout = text.layoutManager, let container = text.textContainer,
                  let content = text.window?.contentView else { return }
            layout.ensureLayout(for: container)
            let location = min(text.selectedRange().location, text.textStorage?.length ?? 0)
            var rect: NSRect
            if layout.numberOfGlyphs == 0 {
                rect = NSRect(x: 0, y: 0, width: 0, height: DraftField.lineHeight)
            } else if location >= (text.textStorage?.length ?? 0) {
                let last = layout.boundingRect(forGlyphRange: NSRange(location: layout.numberOfGlyphs - 1, length: 1), in: container)
                rect = layout.extraLineFragmentRect.height > 0
                    ? NSRect(x: 0, y: layout.extraLineFragmentRect.minY, width: 0, height: last.height)
                    : NSRect(x: last.maxX, y: last.minY, width: 0, height: last.height)
            } else {
                let glyph = layout.glyphIndexForCharacter(at: location)
                rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            }
            let slot = NSRect(x: min(rect.minX, max(text.bounds.width - 40, 0)), y: rect.minY, width: 40, height: ChipAttachment.height)
            let inWindow = text.convert(slot, to: nil)
            let ui = parent.ui
            let global = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            DispatchQueue.main.async { if ui.landing { ui.landingSlot = global } }
        }

        // MARK: You changed the field

        func textDidChange(_ notification: Notification) {
            guard !applying, let text, let storage = text.textStorage else { return }
            // A pasted object character with no chip behind it is not text.
            var stray: [NSRange] = []
            let whole = storage.string as NSString
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard !(value is ChipAttachment) else { return }
                var search = range
                while search.length > 0 {
                    let found = whole.range(of: "\u{FFFC}", options: [], range: search)
                    guard found.location != NSNotFound else { break }
                    stray.append(found)
                    search = NSRange(location: found.upperBound, length: range.upperBound - found.upperBound)
                }
            }
            if !stray.isEmpty {
                applying = true
                for range in stray.reversed() { storage.deleteCharacters(in: range) }
                applying = false
            }
            let now = fieldState()
            let ui = parent.ui
            applying = true
            if ui.draft != now.plain { ui.draft = now.plain }
            let clips: [Clip] = now.chips.compactMap { chip in
                guard var clip = ui.clips.first(where: { $0.id == chip.id }) ?? known[chip.id] else { return nil }
                clip.offset = chip.offset
                return clip
            }
            if clips.map(\.id) != ui.clips.map(\.id) || zip(clips, ui.clips).contains(where: { $0.offset != $1.offset }) {
                if let open = ui.editingClip, !clips.contains(where: { $0.id == open }) { ui.editingClip = nil }
                ui.clips = clips
            }
            applying = false
            text.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Text typed beside a chip is plain text, not part of the chip.
            textView.typingAttributes = DraftField.attributes
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

    }
}

/// The field itself. It takes the first click, also when the island is not the key window.
final class DraftTextView: NSTextView {
    var onChipClick: ((UUID) -> Void)?
    var onChipHover: ((UUID?) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The chip under a point of this view.
    private func chip(at point: NSPoint) -> UUID? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: p, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return (storage.attribute(.attachment, at: index, effectiveRange: nil) as? ChipAttachment)?.clipID
    }

    override func mouseDown(with event: NSEvent) {
        if let id = chip(at: convert(event.locationInWindow, from: nil)) {
            onChipClick?(id)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["chip"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["chip": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let id = chip(at: convert(event.locationInWindow, from: nil))
        onChipHover?(id)
        // A chip is a thing to click, not text.
        if id != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onChipHover?(nil)
    }
}

/// A selection in the message text: its picture and its comment, or what the selection is.
final class ChipAttachment: NSTextAttachment {
    static let height: CGFloat = 20
    let clipID: UUID
    let label: String
    let editing: Bool

    init(clipID: UUID, label: String, editing: Bool, thumbnail: NSImage, strong: Bool) {
        self.clipID = clipID
        self.label = label
        self.editing = editing
        super.init(data: nil, ofType: nil)
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(strong ? 0.95 : 0.7),
        ])
        let picture: CGFloat = 14, pad: CGFloat = 3, gap: CGFloat = 5, trailing: CGFloat = 7, side: CGFloat = 2
        let textWidth = min(ceil(text.size().width), 170)
        let size = NSSize(width: side + pad + picture + gap + textWidth + trailing + side, height: Self.height)
        image = NSImage(size: size, flipped: false) { rect in
            // A little air on both sides, so two chips or a chip and a word do not touch.
            let body = rect.insetBy(dx: side, dy: 0.5)
            let shape = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.12).setFill()
            shape.fill()
            (editing ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.14)).setStroke()
            shape.lineWidth = editing ? 1.5 : 1
            shape.stroke()
            let frame = NSRect(x: body.minX + pad, y: body.midY - picture / 2, width: picture, height: picture)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 3.5, yRadius: 3.5).addClip()
            // Fill the square: cut the longer side.
            let from = thumbnail.size
            let scale = max(picture / max(from.width, 1), picture / max(from.height, 1))
            let drawn = NSSize(width: from.width * scale, height: from.height * scale)
            thumbnail.draw(in: NSRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let line = text.size().height
            text.draw(with: NSRect(x: frame.maxX + gap, y: body.midY - line / 2, width: textWidth, height: line),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        // Sits on the text line: a little under the baseline, as tall as the line allows.
        bounds = NSRect(x: 0, y: -5, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}
