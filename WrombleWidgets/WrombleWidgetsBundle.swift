import WidgetKit
import SwiftUI

// Widget-extension'ens indgang. Indeholder Wromble Live Activity'en (levering).
@main
struct WrombleWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WrombleDeliveryLiveActivity()
    }
}
