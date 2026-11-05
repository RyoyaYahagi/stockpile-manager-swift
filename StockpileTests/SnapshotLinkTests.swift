import Foundation
import Testing
@testable import Stockpile

struct SnapshotLinkTests {

    @Test
    func snapshotHasSchemaEnvelope() throws {
        let item = Item(name: "水 2L", janCode: "4901777018686", quantity: 12, expiryDate: nil)
        let snapshot = SnapshotBuilder.makeSnapshot(
            items: [item],
            familyName: "テスト家",
            generatedAt: Date(timeIntervalSince1970: 1_762_346_400), // 2025-11-05 12:00 UTC
            appVersion: "9.9.9"
        )

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.appVersion == "9.9.9")
        #expect(snapshot.familyName == "テスト家")
        #expect(snapshot.generatedAt.hasPrefix("2025-11-05"))
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items[0].id == item.id.uuidString)
        #expect(snapshot.items[0].name == "水 2L")
        #expect(snapshot.items[0].janCode == "4901777018686")
        #expect(snapshot.items[0].quantity == 12)
        #expect(snapshot.items[0].expiryDate == nil)
    }

    @Test
    func snapshotFormatsExpiryAsDayAndIncludesBag() throws {
        let bag = Bag(name: "非常袋")
        var components = DateComponents()
        components.year = 2027
        components.month = 3
        components.day = 31
        components.hour = 12
        let expiry = Calendar(identifier: .gregorian).date(from: components)
        let item = Item(name: "缶詰", quantity: 3, expiryDate: expiry)
        item.bag = bag

        let snapshot = SnapshotBuilder.makeSnapshot(items: [item], familyName: nil)
        #expect(snapshot.items[0].expiryDate == "2027-03-31")
        #expect(snapshot.items[0].bagName == "非常袋")
    }

    @Test
    func snapshotJSONIsDecodableWithSameShape() throws {
        let item = Item(name: "乾電池", quantity: 8)
        let data = try SnapshotBuilder.makeJSONData(items: [item], familyName: nil)
        let decoded = try JSONDecoder().decode(StockpileSnapshot.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.items.map(\.name) == ["乾電池"])
    }

    @Test
    func endpointValidationRequiresHTTPS() {
        #expect(SnapshotLinkSettings.validatedEndpoint("https://example.workers.dev/v1/snapshot") != nil)
        #expect(SnapshotLinkSettings.validatedEndpoint("http://example.workers.dev/v1/snapshot") == nil)
        #expect(SnapshotLinkSettings.validatedEndpoint("not a url") == nil)
        #expect(SnapshotLinkSettings.validatedEndpoint("") == nil)
    }

    @Test
    func promptContainsURLAndVersionButNoToken() {
        let prompt = SnapshotLinkPrompt.makePrompt(
            snapshotURLString: "https://example.workers.dev/v1/snapshot"
        )
        #expect(prompt.contains("https://example.workers.dev/v1/snapshot"))
        #expect(prompt.contains(SnapshotLinkPrompt.promptVersion))
        #expect(prompt.contains("読み取り専用"))
    }
}
