import Foundation

struct MLXModel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let identifier: String
    let size: String
    let description: String
}