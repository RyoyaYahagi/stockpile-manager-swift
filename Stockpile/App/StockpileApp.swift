import SwiftUI
import SwiftData

@main
struct StockpileApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Family.self,
            User.self,
            Bag.self,
            Item.self,
            NotificationSettings.self
        ])
    }
}
