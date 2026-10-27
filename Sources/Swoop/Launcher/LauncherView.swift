// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import SwoopCore

enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 64, height: 64)
        cache[path] = i
        return i
    }
}

struct ItemIconView: View {
    let icon: ItemIcon
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch icon {
            case .file(let p):
                Image(nsImage: IconCache.icon(for: p)).resizable().interpolation(.high)
            case .image(let img):
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            case .emoji(let e):
                Text(e).font(.system(size: size * 0.8))
            case .symbol(let s):
                Image(systemName: s)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Color.accentColor.opacity(0.85)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// NSTextField wrapper: reliable first-responder handling in a borderless panel.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22, weight: .regular)
        f.delegate = context.coordinator
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastToken = -1
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                resultList
                if let item = model.selectedItem, item.preview != nil || item.previewImage != nil {
                    Divider().opacity(0.5)
                    PreviewPane(item: item).frame(width: 300)
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 760, height: 480)
        .overlay(alignment: .bottomTrailing) {
            if model.showActions, let item = model.selectedItem {
                ActionPanel(item: item, selection: model.actionSelection) { i in
                    model.actionSelection = i
                    model.runSelectedAction()
                }
                .padding(.trailing, 12).padding(.bottom, 44)
            }
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t).font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 4))
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let title = model.mode.title {
                Button { model.enter(.root, query: "") } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(title)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundColor(.secondary)
            }
            SearchField(text: $model.query, placeholder: model.mode.placeholder, focusToken: model.focusToken)
                .frame(height: 30)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        if idx == 0 || model.items[idx - 1].section != item.section {
                            Text(item.section).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                .padding(.horizontal, 14).padding(.top, idx == 0 ? 6 : 10).padding(.bottom, 3)
                        }
                        ResultRow(item: item, selected: idx == model.selection, favourite: model.isFavourite(item.id))
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.selection = idx; model.runPrimary(secondary: false) }
                            .onTapGesture { model.selection = idx }
                    }
                    if model.items.isEmpty {
                        Text("No results").foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .onChange(of: model.selection) { sel in
                if model.items.indices.contains(sel) { proxy.scrollTo(model.items[sel].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "bird").foregroundColor(.accentColor)
            Text("Swoop").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            Spacer()
            if let item = model.selectedItem, let a = item.actions.first {
                HStack(spacing: 4) {
                    Text(a.title).font(.caption)
                    KeyCap("↩")
                }
            }
            Divider().frame(height: 14)
            HStack(spacing: 4) {
                Text("Actions").font(.caption)
                KeyCap("⌘K")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

struct KeyCap: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
    }
}

struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool
    let favourite: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIconView(icon: item.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if favourite { Image(systemName: "star.fill").font(.caption).foregroundColor(.yellow) }
            if let acc = item.accessory {
                Text(acc).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
    }
}

struct PreviewPane: View {
    let item: LauncherItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let p = item.previewImage, let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).cornerRadius(6)
                }
                if let t = item.preview {
                    Text(t).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }
}

struct ActionPanel: View {
    let item: LauncherItem
    let selection: Int
    let onRun: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.caption.weight(.semibold)).foregroundColor(.secondary).lineLimit(1)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(item.actions.enumerated()), id: \.element.id) { i, a in
                HStack {
                    Image(systemName: a.symbol).frame(width: 18)
                    Text(a.title)
                    Spacer()
                    if i == 0 { KeyCap("↩") } else if let s = a.shortcut { KeyCap(s) }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Color.accentColor.opacity(0.25) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { onRun(i) }
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 10))
    }
}
