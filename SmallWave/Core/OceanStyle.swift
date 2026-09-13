import Foundation
import simd

/// One free material for the first physical prototype. Collections come later.
enum OceanStyle {
    static let name = "Blue, yours."
    // Linear reference transmission, calibrated for a clear blue after display encoding.
    static let waterColor = SIMD3<Float>(0.025, 0.18, 0.72)
}

/// An explicit choice applies only to the toy. Unset preferences retain the
/// previous gentle toggle, then defer to the system accessibility preference.
enum OceanMotionResponse: Int, CaseIterable, Identifiable {
    case system, direct, gentle
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .system: return "아이폰 설정 따르기"
        case .direct: return "손 움직임 그대로"
        case .gentle: return "잔잔하게"
        }
    }
    static func resolve(savedValue: Int, legacyGentle: Bool) -> Self {
        Self(rawValue: savedValue) ?? (legacyGentle ? .gentle : .system)
    }
    func reducesMotion(systemPreference: Bool) -> Bool {
        switch self {
        case .system: return systemPreference
        case .direct: return false
        case .gentle: return true
        }
    }
    func detail(systemPreference: Bool) -> String {
        switch self {
        case .system:
            return systemPreference
                ? "아이폰의 ‘동작 줄이기’가 켜져 있어, 바다도 잔잔하게 반응하고 있어."
                : "아이폰 설정에 맞춰 손의 움직임을 그대로 받고 있어."
        case .direct: return "이 바다에서는 빠르게 흔드는 힘까지 그대로 받아."
        case .gentle: return "기울어지는 방향은 따라가고, 흔드는 힘은 부드럽게 받아."
        }
    }
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
