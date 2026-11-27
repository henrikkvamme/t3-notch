import SwiftUI

/// The ⌘K chat list. Split so that moving the selection (spamming ⌃J/⌃K or arrows) only
/// redraws `PickerHighlight`: the rows never read the selected index, and the list is
/// cached in the store, so a keypress costs one rectangle move.
struct ChatPicker: View {
    let store: Store
    @Bindable var ui: OverlayUIState
    let glass: Namespace.ID
    let onPick: (Int) -> Void

    var body: some View {
        let rows = store.pickerRows(query: ui.pickerQuery)
        VStack(alignment: .leading, spacing: 10) { // room between the search field and the list
            TextField("", text: $ui.pickerQuery)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .glassEffectID("field", in: glass)
                .onSubmit { onPick(ui.pickerIndex) }
                .onChange(of: ui.pickerQuery) { ui.pickerIndex = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        PickerHighlight(ui: ui, proxy: proxy)
                        PickerRows(rows: rows, projects: store.projects, ui: ui, onPick: onPick)
                    }
                    .coordinateSpace(.named("pickerRows"))
                }
                .scrollIndicators(.never)
                .frame(height: min(listHeight(count: rows.count), ui.maxReplyHeight))
            }
        }
        .animation(Motion.content, value: ui.pickerQuery)
        .onChange(of: rows.count, initial: true) { _, n in ui.pickerCount = n }
    }

    /// The rows' measured height, so the list is only as tall as its content.
    private func listHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return (0..<count).compactMap { ui.pickerRowFrames[$0]?.maxY }.max() ?? CGFloat(count) * 62
    }
}

/// The rows. They do not read the selection, so moving it never rebuilds them.
private struct PickerRows: View {
    let rows: [JSON]
    let projects: [String: JSON]
    let ui: OverlayUIState
    let onPick: (Int) -> Void

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element["key"].string) { i, t in
                ThreadRow(thread: t, project: projects[Store.projectKey(for: t)], now: now)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(i) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("pickerRows")) }) { frame in
                        if ui.pickerRowFrames[i] != frame { ui.pickerRowFrames[i] = frame }
                    }
                    .id(i)
                    .transition(.blurReplace)
            }
        }
    }
}

/// The one highlight that slides to the selected row, and keeps that row in view.
private struct PickerHighlight: View {
    let ui: OverlayUIState
    let proxy: ScrollViewProxy

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let f = ui.pickerRowFrames[ui.pickerIndex] {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.12))
                    // As wide as the list, whatever width the row had when it was measured.
                    .frame(maxWidth: .infinity).frame(height: f.height)
                    .offset(y: f.minY)
                    .animation(Motion.select, value: f)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: ui.pickerIndex) { _, i in proxy.scrollTo(i) }
    }
}
