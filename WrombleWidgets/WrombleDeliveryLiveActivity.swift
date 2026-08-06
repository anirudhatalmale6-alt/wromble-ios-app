import WidgetKit
import SwiftUI
import ActivityKit

// Wromble-farver (widget-target har ikke adgang til appens globale wrombleRed).
let wrombleRed = Color(red: 226/255, green: 15/255, blue: 30/255)
let wrombleGreen = Color(red: 34/255, green: 197/255, blue: 94/255)

private let stageSteps = ["Modtaget", "Bekraeftet", "Paa vej", "Leveret"]

// Fremdrift 0...1 ud fra stadie (0 modtaget -> 1 leveret).
private func stageProgress(_ stage: Int) -> Double {
    Double(max(0, min(3, stage))) / 3.0
}

private func stageIcon(_ stage: Int) -> String {
    switch stage {
    case 0: return "checkmark.seal.fill"      // modtaget
    case 1: return "fork.knife"               // bekraeftet / tilberedes
    case 2: return "bicycle"                  // paa vej
    default: return "checkmark"               // leveret
    }
}

// Cirkulaer fremdrifts-ring med ikon/tekst i midten - kernen i Wolt-lignende designet.
@available(iOS 16.1, *)
struct WrombleProgressRing: View {
    let stage: Int
    var size: CGFloat = 58
    var lineWidth: CGFloat = 7

    private var delivered: Bool { stage >= 3 }
    private var ringColor: Color { delivered ? wrombleGreen : wrombleRed }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, stageProgress(stage)))
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: stageIcon(stage))
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundColor(delivered ? wrombleGreen : .white)
        }
        .frame(width: size, height: size)
    }
}

// Wromble-maerke (lille roedt "badge" + navn) i stedet for et bitmap-logo.
@available(iOS 16.1, *)
struct WrombleBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(wrombleRed).frame(width: 22, height: 22)
                Image(systemName: "bicycle").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            Text("Wromble").font(.system(size: 14, weight: .heavy)).foregroundColor(.white)
        }
    }
}

// Laaseskaerm / banner-visning af Live Activity'en.
@available(iOS 16.1, *)
struct WrombleLiveActivityLockScreen: View {
    let context: ActivityViewContext<WrombleDeliveryAttributes>

    var body: some View {
        // "Type 3" - stort kort med trin-tidslinje (Modtaget -> Tilberedes -> Paa vej
        // -> Leveret) + minut-badge. Størst mulige lock screen Live Activity paa iOS.
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    WrombleBadge()
                    Text(context.attributes.companyName.isEmpty ? "Din ordre" : context.attributes.companyName)
                        .font(.system(size: 21, weight: .bold)).foregroundColor(.white).lineLimit(1)
                    Text(statusLine)
                        .font(.system(size: 14)).foregroundColor(.white.opacity(0.85)).lineLimit(2)
                }
                Spacer(minLength: 8)
                if !context.state.etaText.isEmpty {
                    VStack(spacing: 0) {
                        Text(etaNumber).font(.system(size: 20, weight: .heavy)).foregroundColor(.white)
                        Text("min.").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(context.state.stage >= 3 ? wrombleGreen : wrombleRed)
                    )
                }
            }
            WrombleStepTimeline(stage: context.state.stage)
        }
        .padding(16)
    }

    // Traekker minut-tallet ud af etaText ("ca. 8 min." -> "8", "8-12 min." -> "8-12").
    private var etaNumber: String {
        let filtered = context.state.etaText.filter { $0.isNumber || $0 == "-" }
        return filtered.isEmpty ? context.state.etaText : filtered
    }

    private var statusLine: String {
        let s = context.state
        if s.stage >= 3 { return "Din ordre er leveret. Velbekomme!" }
        if s.stage == 2 {
            return s.etaText.isEmpty ? "Din ordre er paa vej til dig." : "Paa vej – \(s.etaText)"
        }
        if s.stage == 1 { return "Restauranten er gaaet i gang med din ordre." }
        return "Din ordre er modtaget."
    }
}

// Vandret 4-trins tidslinje med forbindelses-streger + ikoner. Fyldes roedt op til
// og med det aktuelle trin; det aktive trin faar en bloed "glow"-ring.
@available(iOS 16.1, *)
struct WrombleStepTimeline: View {
    let stage: Int
    private let steps: [(icon: String, cap: String)] = [
        ("checkmark", "Modtaget"),
        ("fork.knife", "Tilberedes"),
        ("bicycle", "På vej"),
        ("house.fill", "Leveret")
    ]
    private let track = Color.white.opacity(0.16)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                VStack(spacing: 7) {
                    ZStack {
                        // Forbindelses-streg (venstre + hoejre halvdel af cellen).
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(idx == 0 ? Color.clear : (stage >= idx ? wrombleRed : track))
                                .frame(height: 3)
                            Rectangle()
                                .fill(idx == steps.count - 1 ? Color.clear : (stage >= idx + 1 ? wrombleRed : track))
                                .frame(height: 3)
                        }
                        if stage == idx {
                            Circle().fill(wrombleRed.opacity(0.28)).frame(width: 40, height: 40)
                        }
                        Circle()
                            .fill(stage >= idx ? wrombleRed : Color.white.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: step.icon)
                            .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    }
                    Text(step.cap)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(stage >= idx ? .white : .white.opacity(0.7))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

@available(iOS 16.1, *)
struct WrombleDeliveryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WrombleDeliveryAttributes.self) { context in
            WrombleLiveActivityLockScreen(context: context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WrombleProgressRing(stage: context.state.stage, size: 48, lineWidth: 6)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.statusLabel).font(.system(size: 15, weight: .bold))
                            .foregroundColor(context.state.stage >= 3 ? wrombleGreen : wrombleRed)
                        if !context.state.etaText.isEmpty {
                            Text(context.state.etaText).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.companyName.isEmpty ? "Wromble-levering" : context.attributes.companyName)
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                }
            } compactLeading: {
                Image(systemName: stageIcon(context.state.stage))
                    .foregroundColor(context.state.stage >= 3 ? wrombleGreen : wrombleRed)
            } compactTrailing: {
                WrombleProgressRing(stage: context.state.stage, size: 20, lineWidth: 3)
            } minimal: {
                WrombleProgressRing(stage: context.state.stage, size: 20, lineWidth: 3)
            }
            .keylineTint(wrombleRed)
        }
    }
}
