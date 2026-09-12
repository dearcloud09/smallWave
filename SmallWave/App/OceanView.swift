import SwiftUI
import Combine

final class OceanControls: ObservableObject {
    weak var renderer: LiquidRenderer?
    let sensory = SensoryFeedback()
    @Published var rendererError: String?
    @Published var sensoryMessage: String?
    init() { sensory.onStatus = { [weak self] in self?.sensoryMessage = $0 } }
    func reset() { renderer?.reset() }
}

struct OceanView: View {
    @StateObject private var motion = MotionInput()
    @StateObject private var controls = OceanControls()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("smallwave.sound") private var sound = false
    @AppStorage("smallwave.haptics") private var haptics = true
    @AppStorage("smallwave.reducedMotion") private var reducedMotion = false
    @AppStorage("smallwave.miniature") private var miniatureID = MiniatureStyle.sunday.rawValue
    @State private var settings = false
    @State private var paused = false
    @State private var showHint = true

    private let ink = Color(red: 0.16, green: 0.26, blue: 0.28)
    private var miniatureStyle: MiniatureStyle { MiniatureStyle(rawValue: miniatureID) ?? .sunday }

    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.94, blue: 0.89).ignoresSafeArea()
            LiquidMetalView(motion: motion, controls: controls,
                            active: scenePhase == .active && !paused && !settings,
                            sound: sound, haptics: haptics,
                            reducedMotion: reducedMotion || systemReduceMotion,
                            miniatureStyle: miniatureStyle)
                .ignoresSafeArea()
                .accessibilityLabel("푸른 액체와 작은 범선. \(miniatureStyle.detail). 아이폰을 기울이고 흔들어봐.")
                .accessibilityAddTraits(.isImage)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("smallwave")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .tracking(-0.8)
                    Spacer()
                    Text("네 손안의 작은 바다")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .opacity(0.6)
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 27)
                .padding(.top, 15)
                Spacer()
                if let error = controls.rendererError {
                    VStack(spacing: 8) {
                        Text("바다를 준비하지 못했어").font(.headline)
                        Text(error).font(.caption).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(28)
                }
                Spacer()
                if showHint {
                    Text(motion.unavailable ? "움직임 센서를 연결하지 못했어. 바다는 감상할 수 있어." : "기울이고, 흔들고, 잠깐 바라봐.")
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
                HStack {
                    Button {
                        paused.toggle()
                        if paused { controls.sensory.stop() }
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(paused ? "움직임 다시 시작" : "이 모습으로 잠시 멈추기")
                    Spacer()
                    Text("BLUE, YOURS.")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(2.3)
                        .opacity(0.7)
                    Spacer()
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("바다 설정")
                }
                .foregroundStyle(ink)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(maxWidth: 260)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.light)
        .onAppear { motion.start() }
        .onDisappear { motion.stop(); controls.sensory.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { motion.start() }
            else { motion.stop(); controls.sensory.stop() }
        }
        .onChange(of: settings) { _, shown in
            if !shown { controls.sensory.stopPreview() }
        }
        .onOpenURL { url in
            guard url.scheme == "smallwave", url.host == "ocean" else { return }
            settings = false
            paused = false
        }
        .task {
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1)) { showHint = false }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section {
                        Picker("작은 배", selection: $miniatureID) {
                            ForEach(MiniatureStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text("작은 배의 색")
                    } footer: {
                        Text(miniatureStyle.detail)
                    }
                    Section {
                        Toggle("물소리", isOn: $sound)
                        Button("2초 동안 물소리 들어보기") { controls.sensory.preview() }
                            .disabled(!sound)
                        if let message = controls.sensoryMessage {
                            Text(message).font(.caption).foregroundStyle(ink)
                        }
                        Toggle("잔잔한 진동", isOn: $haptics)
                        Toggle("흔들림 줄이기", isOn: $reducedMotion)
                    } header: {
                        Text("감각")
                    } footer: {
                        Text("물소리는 설정을 닫고 기울이거나 흔들 때 나. 아이폰 무음 모드에서는 들리지 않아.")
                    }
                    Section {
                        Button("바다를 다시 가라앉히기") {
                            motion.stop()
                            motion.start()
                            controls.reset()
                            paused = false
                            settings = false
                        }
                    } footer: {
                        Text("배를 바꿔도 같은 바다의 움직임이 이어져.")
                    }
                }
                .navigationTitle("나의 작은 바다")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { controls.sensory.stopPreview(); settings = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
