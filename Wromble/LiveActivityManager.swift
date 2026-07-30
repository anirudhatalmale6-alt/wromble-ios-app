import Foundation
import ActivityKit

// Styrer Wromble leverings-Live Activity (laaseskaerm + Dynamic Island).
// Fase 1: starter og opdaterer aktiviteten mens appen koerer (fx paa sporings-
// skaermen der poller hvert 12. sek). Server-push (opdatering mens telefonen er
// laast/appen lukket) tilfoejes i fase 2 via aktivitetens push-token.
@available(iOS 16.1, *)
enum WrombleLiveActivityManager {

    static func sync(orderId: Int, companyName: String, stage: Int, statusLabel: String, etaText: String) {
        guard orderId > 0 else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = WrombleDeliveryAttributes.ContentState(stage: stage, statusLabel: statusLabel, etaText: etaText)

        if let act = Activity<WrombleDeliveryAttributes>.activities.first(where: { $0.attributes.orderId == orderId }) {
            Task {
                await act.update(using: state)
                if stage >= 3 {
                    // Leveret: lad den ligge kort tid, saa kunden ser "Leveret", og luk saa.
                    await act.end(using: state, dismissalPolicy: .after(Date().addingTimeInterval(120)))
                }
            }
        } else if stage >= 0 && stage < 3 {
            // Start kun en ny aktivitet for en igangvaerende ordre (ikke en afsluttet/afvist).
            let attrs = WrombleDeliveryAttributes(orderId: orderId, companyName: companyName)
            _ = try? Activity.request(attributes: attrs, contentState: state, pushType: nil)
        }
    }

    // Afslut alle leverings-aktiviteter med det samme (fx ved log ud).
    static func endAll() {
        for act in Activity<WrombleDeliveryAttributes>.activities {
            Task { await act.end(dismissalPolicy: .immediate) }
        }
    }
}
