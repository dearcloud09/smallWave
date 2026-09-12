import Foundation
import simd

/// One free material for the first physical prototype. Collections come later.
enum OceanStyle {
    static let name = "Blue, yours."
    // Linear reference transmission, calibrated for a clear blue after display encoding.
    static let waterColor = SIMD3<Float>(0.025, 0.18, 0.72)
}

/// Three paint colors on one handcrafted silhouette and one floating-body state.
enum MiniatureStyle: Int, CaseIterable, Identifiable {
    // Keep the existing raw IDs so saved selections remain valid.
    case sunday, harbour, drift
    var id: Int { rawValue }
    var textureAssetName: String { "toy-boat-blue" }
    var assetName: String {
        switch self {
        case .sunday: return "toy-blue"
        case .harbour: return "toy-yellow"
        case .drift: return "toy-red"
        }
    }
    var title: String {
        switch self {
        case .sunday: return "마린 블루"
        case .harbour: return "햇살 옐로"
        case .drift: return "브릭 레드"
        }
    }
    var detail: String {
        switch self {
        case .sunday: return "파란 나무 선체 · 상아색 천 돛 · 작은 빨간 구명환"
        case .harbour: return "노란 나무 선체 · 상아색 천 돛 · 작은 빨간 구명환"
        case .drift: return "빨간 나무 선체 · 상아색 천 돛 · 작은 남색 구명환"
        }
    }
}
