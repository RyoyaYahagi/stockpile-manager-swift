import Foundation
import SwiftData

/// ユーザーモデル
@Model
final class User {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var email: String?
    var lineUserId: String?
    var appleUserId: String?
    var createdAt: Date
    
    var family: Family?
    
    init(displayName: String, email: String? = nil, appleUserId: String? = nil) {
        self.id = UUID()
        self.displayName = displayName
        self.email = email
        self.appleUserId = appleUserId
        self.createdAt = Date()
    }
}
