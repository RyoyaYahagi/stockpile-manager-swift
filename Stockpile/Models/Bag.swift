import Foundation
import SwiftData

/// 収納場所モデル
/// 物理的な収納場所（非常袋、車載ボックス等）
@Model
final class Bag {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    
    var family: Family?
    
    @Relationship(deleteRule: .nullify, inverse: \Item.bag)
    var items: [Item] = []
    
    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
    }
}
