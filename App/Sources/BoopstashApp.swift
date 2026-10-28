import BoopstashCore
import SwiftUI

@main
struct BoopstashApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                ProductInfo.name,
                systemImage: "tray.full",
                description: Text("Nothing here yet.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
