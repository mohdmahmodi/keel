import SwiftUI

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.title).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(Theme.small).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing
        }
        .buttonStyle(.keel)
        .frame(minHeight: 40)
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

struct EqualRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Stretches a card to fill its cell in an EqualRow.
    func cell() -> some View { frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
}

/// Search field without the system accent focus ring.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused(focus)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", size: 11) { text = "" }.frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focus.wrappedValue ? Theme.borderStrong : Theme.border, lineWidth: 1))
        .focusEffectDisabled()
    }
}

struct EmptyNote: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
            Text(text).font(Theme.small).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}

struct VLine: View {
    var body: some View { Rectangle().fill(Theme.border).frame(width: 1) }
}
struct HLine: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

extension View {
    /// Plain text field in a 1 px bordered box, without the system accent focus ring.
    func keelTextField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 8).frame(height: 26)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .focusEffectDisabled()
    }
}
