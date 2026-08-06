import Foundation
import ActivityKit

// Styrer Wromble leverings-Live Activity (laaseskaerm + Dynamic Island).
// Fase 1: starter og opdaterer aktiviteten mens appen koerer (fx paa sporings-
// skaermen der poller hvert 12. sek). Server-push (opdatering mens telefonen er
// laast/appen lukket) tilfoejes i fase 2 via aktivitetens push-token.
@available(iOS 16.1, *)
enum WrombleLiveActivityManager {

    // Ordrer vi allerede lytter paa push-token for (undgaar dublerede observatoerer).
    private static var observing = Set<Int>()

    static func sync(orderId: Int, companyName: String, stage: Int, statusLabel: String, etaText: String) {
        guard orderId > 0 else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = WrombleDeliveryAttributes.ContentState(stage: stage, statusLabel: statusLabel, etaText: etaText)

        if let act = Activity<WrombleDeliveryAttributes>.activities.first(where: { $0.attributes.orderId == orderId }) {
            observePushToken(act, orderId: orderId)   // gen-registrer token efter app-genstart
            Task {
                await act.update(using: state)
                if stage >= 3 {
                    // Leveret: lad den ligge kort tid, saa kunden ser "Leveret", og luk saa.
                    await act.end(using: state, dismissalPolicy: .after(Date().addingTimeInterval(120)))
                }
            }
        } else if stage >= 0 && stage < 3 {
            // Start kun en ny aktivitet for en igangvaerende ordre (ikke en afsluttet/afvist).
            // pushType: .token => serveren kan opdatere ringen mens telefonen er laast
            // og appen lukket (fase 2). Vi lytter paa token'et og sender det til serveren.
            let attrs = WrombleDeliveryAttributes(orderId: orderId, companyName: companyName)
            if let act = try? Activity.request(attributes: attrs, contentState: state, pushType: .token) {
                observePushToken(act, orderId: orderId)
            }
        }
    }

    // Lytter paa aktivitetens push-token og registrerer det hos serveren pr. ordre.
    private static func observePushToken(_ activity: Activity<WrombleDeliveryAttributes>, orderId: Int) {
        guard !observing.contains(orderId) else { return }
        observing.insert(orderId)
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                registerActivityToken(orderId: orderId, token: token)
            }
            observing.remove(orderId)
        }
    }

    private static func registerActivityToken(orderId: Int, token: String) {
        guard let url = URL(string: "\(baseURL)/api/register-activity-token.php") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["order_id": orderId, "token": token])
        URLSession.shared.dataTask(with: req).resume()
    }

    // --- CHAUFFØR-kort (Type 3) --------------------------------------------
    // Chaufføerens eget leverings-kort. Styres LOKALT af appen (ingen server-push /
    // ingen aktivitets-token), fordi chaufføren selv udloeser trinene (paa vej -> leveret).
    // Vi bruger derfor IKKE pushType: .token her - saa vi heller ikke overskriver
    // kundens aktivitets-token for samme ordre paa serveren.
    static func startDriver(orderId: Int, title: String, stage: Int, statusLabel: String, etaText: String) {
        guard orderId > 0, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = WrombleDeliveryAttributes.ContentState(stage: stage, statusLabel: statusLabel, etaText: etaText)
        if let act = Activity<WrombleDeliveryAttributes>.activities.first(where: { $0.attributes.orderId == orderId }) {
            Task { await act.update(using: state) }
        } else {
            let attrs = WrombleDeliveryAttributes(orderId: orderId, companyName: title, role: "driver")
            _ = try? Activity.request(attributes: attrs, contentState: state)   // lokal (ingen pushType)
        }
    }

    static func updateDriver(orderId: Int, stage: Int, statusLabel: String, etaText: String, end: Bool = false) {
        guard orderId > 0 else { return }
        let state = WrombleDeliveryAttributes.ContentState(stage: stage, statusLabel: statusLabel, etaText: etaText)
        Task {
            for act in Activity<WrombleDeliveryAttributes>.activities where act.attributes.orderId == orderId {
                if end { await act.end(using: state, dismissalPolicy: .after(Date().addingTimeInterval(30))) }
                else { await act.update(using: state) }
            }
        }
    }

    // Afslut alle leverings-aktiviteter med det samme (fx ved log ud).
    static func endAll() {
        for act in Activity<WrombleDeliveryAttributes>.activities {
            Task { await act.end(dismissalPolicy: .immediate) }
        }
    }
}
