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
    func fingerprintIsStableForSameContentAndChangesWithEdits() {
        let item = Item(name: "水 2L", quantity: 12)
        let first = SnapshotFingerprint.compute(items: [item], familyName: "テスト家")
        let second = SnapshotFingerprint.compute(items: [item], familyName: "テスト家")
        #expect(!first.isEmpty)
        #expect(first == second)

        item.quantity = 11
        let afterEdit = SnapshotFingerprint.compute(items: [item], familyName: "テスト家")
        #expect(afterEdit != first)

        let otherFamily = SnapshotFingerprint.compute(items: [item], familyName: "別家")
        #expect(otherFamily != afterEdit)
    }

    @Test
    func autoUploadPolicyRequiresEverythingAndAChange() {
        let url = URL(string: "https://example.workers.dev/v1/snapshot")
        #expect(
            SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: true, isAutoUploadEnabled: true, endpoint: url,
                hasWriteToken: true, fingerprint: "abc", lastUploadedFingerprint: "xyz"))
        #expect(
            !SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: true, isAutoUploadEnabled: true, endpoint: url,
                hasWriteToken: true, fingerprint: "abc", lastUploadedFingerprint: "abc"))
        #expect(
            !SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: false, isAutoUploadEnabled: true, endpoint: url,
                hasWriteToken: true, fingerprint: "abc", lastUploadedFingerprint: nil))
        #expect(
            !SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: true, isAutoUploadEnabled: false, endpoint: url,
                hasWriteToken: true, fingerprint: "abc", lastUploadedFingerprint: nil))
        #expect(
            !SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: true, isAutoUploadEnabled: true, endpoint: nil,
                hasWriteToken: true, fingerprint: "abc", lastUploadedFingerprint: nil))
        #expect(
            !SnapshotAutoUploadPolicy.shouldUpload(
                isLinkEnabled: true, isAutoUploadEnabled: true, endpoint: url,
                hasWriteToken: false, fingerprint: "abc", lastUploadedFingerprint: nil))
    }

    @Test
    func autoUploadSettingsRoundTrip() {
        let previousAuto = SnapshotLinkSettings.autoUploadEnabled
        let previousFingerprint = SnapshotLinkSettings.lastUploadedFingerprint
        defer {
            SnapshotLinkSettings.autoUploadEnabled = previousAuto
            SnapshotLinkSettings.lastUploadedFingerprint = previousFingerprint
        }

        SnapshotLinkSettings.autoUploadEnabled = true
        SnapshotLinkSettings.lastUploadedFingerprint = "deadbeef"
        #expect(SnapshotLinkSettings.autoUploadEnabled)
        #expect(SnapshotLinkSettings.lastUploadedFingerprint == "deadbeef")
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

    @Test
    func driveWritePromptHasVersionAndWriteGuides() {
        let prompt = SnapshotLinkPrompt.makeDriveWritePrompt()
        #expect(prompt.contains(SnapshotLinkPrompt.writePromptVersion))
        #expect(prompt.contains("書き込み権限"))
        #expect(prompt.contains("承認制"))
        #expect(prompt.contains("baseUpdatedAt"))
        #expect(prompt.contains("commands.json"))
        #expect(prompt.contains("command-results.json"))
        #expect(prompt.contains("作り直"))
        #expect(prompt.contains("7日"))
        #expect(prompt.contains("書き込む前に"))
        #expect(prompt.contains("applied"))
        #expect(prompt.contains("conflict"))
    }

    @Test
    func customURLWritePromptUsesCommandEndpoints() {
        let prompt = SnapshotLinkPrompt.makeWritePrompt(
            snapshotURLString: "https://example.workers.dev/v1/snapshot"
        )
        #expect(prompt.contains(SnapshotLinkPrompt.writePromptVersion))
        #expect(prompt.contains("https://example.workers.dev/v1/snapshot"))
        #expect(prompt.contains("https://example.workers.dev/v1/commands"))
        #expect(prompt.contains("https://example.workers.dev/v1/command-results"))
        #expect(prompt.contains("COMMANDS_TOKEN"))
        #expect(prompt.contains("承認制"))
        #expect(prompt.contains("baseUpdatedAt"))
        #expect(prompt.contains("書き込む前に"))

        let emptyPrompt = SnapshotLinkPrompt.makeWritePrompt(snapshotURLString: "")
        #expect(emptyPrompt.contains("（設定した送信先URL）"))
    }

    @Test
    func writePromptsDoNotContainTokenValues() {
        let drivePrompt = SnapshotLinkPrompt.makeDriveWritePrompt()
        let customURLPrompt = SnapshotLinkPrompt.makeWritePrompt(
            snapshotURLString: "https://example.workers.dev/v1/snapshot")

        // Drive はトークンを使わず、カスタムURLは名前だけを案内して値は載せない。
        #expect(customURLPrompt.contains("このチャットには貼りません"))
        #expect(!drivePrompt.contains("COMMANDS_TOKEN"))
        for prompt in [drivePrompt, customURLPrompt] {
            #expect(prompt.range(of: "[0-9a-fA-F]{32,}", options: .regularExpression) == nil)
            #expect(!prompt.contains("Bearer "))
            #expect(!prompt.contains("COMMANDS_TOKEN="))
            #expect(!prompt.contains("READ_TOKEN="))
        }
    }

    @Test
    func setupPromptSwitchesByWritePermission() {
        let url = "https://example.workers.dev/v1/snapshot"

        #expect(
            SnapshotLinkPrompt.makeSetupPrompt(
                destination: .customURL, writesEnabled: false, snapshotURLString: url)
                == SnapshotLinkPrompt.makePrompt(snapshotURLString: url))
        #expect(
            SnapshotLinkPrompt.makeSetupPrompt(
                destination: .googleDrive, writesEnabled: false, snapshotURLString: url)
                == SnapshotLinkPrompt.makeDrivePrompt())
        #expect(
            SnapshotLinkPrompt.makeSetupPrompt(
                destination: .customURL, writesEnabled: true, snapshotURLString: url)
                == SnapshotLinkPrompt.makeWritePrompt(snapshotURLString: url))
        #expect(
            SnapshotLinkPrompt.makeSetupPrompt(
                destination: .googleDrive, writesEnabled: true, snapshotURLString: url)
                == SnapshotLinkPrompt.makeDriveWritePrompt())

        let offDrive = SnapshotLinkPrompt.makeSetupPrompt(
            destination: .googleDrive, writesEnabled: false, snapshotURLString: url)
        let onDrive = SnapshotLinkPrompt.makeSetupPrompt(
            destination: .googleDrive, writesEnabled: true, snapshotURLString: url)
        #expect(!offDrive.contains(SnapshotLinkPrompt.writePromptVersion))
        #expect(onDrive.contains(SnapshotLinkPrompt.writePromptVersion))
    }
}
