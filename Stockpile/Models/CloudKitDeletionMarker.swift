import Foundation
import SwiftData

enum CloudKitDeletionMarkerEntityType: String {
    case bag
    case item
}

@Model
final class CloudKitDeletionMarker {
    var id: UUID = UUID()
    var familyID: UUID = UUID()
    var entityTypeRawValue: String = CloudKitDeletionMarkerEntityType.item.rawValue
    var targetRecordID: String = ""
    var deletedAt: Date = Date()
    var isPendingUpload: Bool = true

    init(
        familyID: UUID,
        entityType: CloudKitDeletionMarkerEntityType,
        targetRecordID: String,
        deletedAt: Date = Date(),
        isPendingUpload: Bool = true
    ) {
        self.id = UUID()
        self.familyID = familyID
        self.entityTypeRawValue = entityType.rawValue
        self.targetRecordID = targetRecordID
        self.deletedAt = deletedAt
        self.isPendingUpload = isPendingUpload
    }

    var entityType: CloudKitDeletionMarkerEntityType {
        get { CloudKitDeletionMarkerEntityType(rawValue: entityTypeRawValue) ?? .item }
        set { entityTypeRawValue = newValue.rawValue }
    }

    var targetUUID: UUID? {
        UUID(uuidString: targetRecordID)
    }
}
