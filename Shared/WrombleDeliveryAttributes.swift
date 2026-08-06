import Foundation
import ActivityKit

// Delt mellem hoved-appen og widget-extensionen. Beskriver en igangvaerende
// Wromble-levering, saa Live Activity'en (laaseskaerm + Dynamic Island) kan vise
// og opdatere leveringens status i realtid - ligesom Wolt.
@available(iOS 16.1, *)
struct WrombleDeliveryAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var stage: Int          // 0 = modtaget, 1 = bekraeftet, 2 = paa vej, 3 = leveret
        var statusLabel: String // fx "Paa vej", "Leveret"
        var etaText: String     // fx "ca. 8 min." (tom hvis ukendt)
    }
    var orderId: Int
    var companyName: String
    // "customer" = kundens spor-kort; "driver" = chaufføerens leverings-kort (lokalt styret).
    var role: String = "customer"
}
