import SwiftUI
import AppKit

/// Flat theme that follows the system appearance. Colour only carries state:
/// green = on, amber = warning, red = failed. Everything else is greyscale.
enum Theme {
    static let radius: CGFloat = 8

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func g(_ v: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(white: v, alpha: a) }

    static let on = dynamic(dark: NSColor(red: 0.33, green: 0.80, blue: 0.50, alpha: 1), light: NSColor(red: 0.12, green: 0.56, blue: 0.29, alpha: 1))
    static let warn = dynamic(dark: NSColor(red: 0.95, green: 0.72, blue: 0.28, alpha: 1), light: NSColor(red: 0.70, green: 0.46, blue: 0.02, alpha: 1))
    static let fail = dynamic(dark: NSColor(red: 0.96, green: 0.42, blue: 0.40, alpha: 1), light: NSColor(red: 0.76, green: 0.19, blue: 0.17, alpha: 1))
    static let neutral = Color.secondary

    static let bg = dynamic(dark: g(0.085), light: g(0.965))
    static let sidebarBG = dynamic(dark: g(0.065), light: g(0.935))
    static let cardBG = dynamic(dark: g(0.115), light: g(1.0))
    static let raisedBG = dynamic(dark: g(0.10), light: g(0.985))
    static let border = dynamic(dark: g(1, 0.085), light: g(0, 0.10))
    static let borderStrong = dynamic(dark: g(1, 0.30), light: g(0, 0.32))
    static let fill = dynamic(dark: g(1, 0.06), light: g(0, 0.05))
    static let hover = dynamic(dark: g(1, 0.045), light: g(0, 0.04))
    static let selection = dynamic(dark: g(1, 0.085), light: g(0, 0.07))
    /// Text on a `Color.primary` fill (primary buttons).
    static let inverse = dynamic(dark: g(0.08), light: g(1.0))

    // Mono only for values and commands.
    static let title = Font.system(size: 18, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11.5)
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoLarge = Font.system(size: 22, weight: .medium, design: .monospaced)

    static func color(for state: TweakState) -> Color {
        switch state {
        case .on: return on
        case .partlyOn: return warn
        case .off, .notApplicable, .unknown: return neutral
        }
    }
    static func color(for risk: Risk) -> Color { risk == .medium ? warn : neutral }
    static func color(for level: LogLevel) -> Color {
        switch level {
        case .success: return on
        case .warning: return warn
        case .error: return fail
        case .info, .command: return neutral
        }
    }
    static func color(for pressure: MemoryPressure) -> Color {
        switch pressure { case .normal: return on; case .warning: return warn; case .critical: return fail }
    }
}

// MARK: - Card

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    var selected = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(selected ? Theme.borderStrong : Theme.border, lineWidth: 1))
    }
}
extension View {
    func card(padding: CGFloat = 14, selected: Bool = false) -> some View { modifier(CardStyle(padding: padding, selected: selected)) }
}

// MARK: - Chips

/// Small status chip: uppercase text, 1 px border, colour only for state.
struct Chip: View {
    let text: String
    var color: Color = Theme.neutral
    var filled: Bool = false
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(Theme.label).tracking(0.3)
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 6).frame(height: 18)
        .foregroundStyle(color)
        .background(filled ? color.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color.opacity(filled ? 0.55 : 0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct StateChip: View {
    let state: TweakState
    /// True while detection has not returned yet; an unknown result after detection reads UNKNOWN.
    var checking = false
    var body: some View {
        Chip(text: checking ? "CHECKING" : (state == .notApplicable ? "NOT ON THIS MAC" : state.rawValue),
             color: Theme.color(for: state), filled: state == .on || state == .partlyOn)
    }
}

struct RiskChip: View {
    let risk: Risk
    var body: some View { Chip(text: risk.rawValue, color: Theme.color(for: risk)).help("Risk: \(risk.rawValue.lowercased())") }
}

struct ImpactChip: View {
    let impact: Impact
    var compact = false
    var body: some View {
        let short: String = {
            switch impact { case .high: return "HIGH"; case .medium: return "MEDIUM"; case .low: return "LOW"; case .cosmetic: return "COSMETIC" }
        }()
        Chip(text: compact || impact == .cosmetic ? short : impact.rawValue, symbol: "gauge.with.dots.needle.33percent")
            .help("Impact: \(impact.rawValue.lowercased())")
            .opacity(impact == .cosmetic ? 0.75 : 1)
    }
}

// MARK: - Buttons

enum KeelButtonKind { case primary, secondary, ghost, danger }

struct KeelButtonStyle: ButtonStyle {
    var kind: KeelButtonKind = .secondary
    var small = false
    func makeBody(configuration: Configuration) -> some View { KeelButtonBody(configuration: configuration, kind: kind, small: small) }

    fileprivate struct KeelButtonBody: View {
        let configuration: Configuration
        let kind: KeelButtonKind
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 12.5, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, small ? 8 : 11)
                .frame(height: small ? 22 : 27)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(borderColor, lineWidth: kind == .ghost || kind == .primary ? 0 : 1))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hover = $0 }
        }
        var foreground: Color {
            switch kind {
            case .primary: return Theme.inverse
            case .secondary: return .primary
            case .ghost: return hover ? .primary : .secondary
            case .danger: return Theme.fail
            }
        }
        var background: Color {
            switch kind {
            case .primary: return Color.primary.opacity(hover && enabled ? 0.85 : 1)
            case .secondary, .danger: return hover && enabled ? Theme.selection : Theme.cardBG
            case .ghost: return hover && enabled ? Theme.hover : .clear
            }
        }
        var borderColor: Color { kind == .danger ? Theme.fail.opacity(0.45) : Theme.border }
    }
}

extension ButtonStyle where Self == KeelButtonStyle {
    static var keel: KeelButtonStyle { KeelButtonStyle() }
    static var keelPrimary: KeelButtonStyle { KeelButtonStyle(kind: .primary) }
    static var keelGhost: KeelButtonStyle { KeelButtonStyle(kind: .ghost) }
    static var keelDanger: KeelButtonStyle { KeelButtonStyle(kind: .danger) }
    static var keelSmall: KeelButtonStyle { KeelButtonStyle(small: true) }
}

/// Icon-only button with a required accessibility label (also used as the tooltip).
struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .background(hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Text pieces

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.label).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6)
            Spacer(minLength: 6)
            if let trailing { Text(trailing).font(Theme.monoSmall).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Key → mono value row.
struct KV: View {
    let k: String
    let v: String
    var color: Color? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).foregroundStyle(.secondary).font(Theme.small).lineLimit(1)
            Spacer(minLength: 8)
            Text(v).font(Theme.mono).foregroundStyle(color ?? .primary).lineLimit(1).truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Verbatim command block with a copy button.
struct CommandBlock: View {
    let lines: [String]
    @State private var copied = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(Theme.monoSmall).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8).padding(.leading, 9).padding(.trailing, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "Copy commands", size: 10.5) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
            .padding(3)
        }
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Selectable chip used for filters.
struct ChipButton: View {
    let text: String
    let selected: Bool
    var count: Int? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                if let count { Text("\(count)").font(Theme.monoSmall).foregroundStyle(.secondary) }
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).frame(height: 24)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? Theme.selection : (hover ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Theme.borderStrong.opacity(0.6) : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Real switch, green when on.
struct FlatToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(SwitchToggleStyle(tint: Theme.on)).controlSize(.small).labelsHidden()
    }
}

struct Bar: View {
    let fraction: Double
    var color: Color = .primary
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(color == .primary ? Color.primary.opacity(0.55) : color.opacity(0.85)).frame(width: max(0, min(1, fraction.isFinite ? fraction : 0)) * g.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Minimal line of recent values (0…1).
struct Sparkline: View {
    let values: [Double]
    var color: Color = .primary
    var capacity = 60
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(1, capacity - 1))
            let start = size.width - step * CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: start + CGFloat(i) * step, y: size.height - CGFloat(max(0, min(1, v))) * (size.height - 1) - 0.5)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1.2)
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Theme.fill), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Checkbox without the system accent colour.
struct KeelCheckboxStyle: ToggleStyle {
    var labelHidden = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Color.primary : Theme.cardBG)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Theme.borderStrong, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inverse)
                    }
                }
                .frame(width: 15, height: 15)
                if !labelHidden { configuration.label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}
