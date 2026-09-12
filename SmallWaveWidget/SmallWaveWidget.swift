import SwiftUI
import WidgetKit

/// 단계 0의 정지 위젯이다. 설정 동기화, 날씨, 네트워크, 위치, App Group은 아직 연결하지 않는다.
struct SmallWaveEntry: TimelineEntry {
    let date: Date
}

struct SmallWaveProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmallWaveEntry { SmallWaveEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SmallWaveEntry) -> Void) {
        completion(SmallWaveEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SmallWaveEntry>) -> Void) {
        completion(Timeline(entries: [SmallWaveEntry(date: .now)], policy: .never))
    }
}

struct SmallWaveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SmallWaveWidget", provider: SmallWaveProvider()) { entry in
            SmallWaveWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("나의 작은 바다")
        .description("기본 푸른 바다와 작은 범선을 보여줘.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

private struct SmallWaveWidgetEntryView: View {
    let entry: SmallWaveEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                lockScreenOcean
            } else {
                oceanArtwork
            }
        }
        .widgetURL(URL(string: "smallwave://ocean"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("나의 작은 바다, 푸른 물 위 작은 범선")
    }

    private var oceanArtwork: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.95, green: 0.91, blue: 0.80)
                WaveSurface()
                    .fill(Color(red: 0.10, green: 0.40, blue: 0.69).opacity(0.28))
                    .frame(height: proxy.size.height * 0.58)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                WaveSurface()
                    .fill(LinearGradient(colors: [Color(red: 0.04, green: 0.26, blue: 0.53), Color(red: 0.02, green: 0.12, blue: 0.34)], startPoint: .top, endPoint: .bottom))
                    .frame(height: proxy.size.height * 0.54)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Sailboat()
                    .frame(width: min(proxy.size.width * 0.34, 95), height: proxy.size.height * 0.42)
                    .offset(x: proxy.size.width * 0.10, y: proxy.size.height * 0.06)
            }
            .clipShape(ContainerRelativeShape())
        }
    }

    private var lockScreenOcean: some View {
        HStack(spacing: 8) {
            ZStack {
                WaveSurface().fill(Color.primary.opacity(renderingMode == .accented ? 0.75 : 0.35))
                Sailboat().padding(8)
            }
            .frame(width: 48, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("나의 작은 바다").font(.headline)
                Text("푸른 바다 · 작은 범선").font(.caption2)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WaveSurface: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.18))
        path.addCurve(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.12), control1: CGPoint(x: rect.width * 0.18, y: rect.height * 0.02), control2: CGPoint(x: rect.width * 0.35, y: rect.height * 0.28))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.20), control1: CGPoint(x: rect.width * 0.72, y: -rect.height * 0.02), control2: CGPoint(x: rect.width * 0.87, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct Sailboat: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Capsule().fill(.white.opacity(0.92)).frame(width: w * 0.68, height: max(4, h * 0.08)).offset(y: h * 0.29)
                Rectangle().fill(Color(red: 0.18, green: 0.15, blue: 0.12)).frame(width: max(1.5, w * 0.035), height: h * 0.62).offset(y: -h * 0.02)
                Triangle().fill(.white).frame(width: w * 0.40, height: h * 0.42).offset(x: w * 0.19, y: -h * 0.12)
                Triangle().fill(Color(red: 0.91, green: 0.31, blue: 0.23)).frame(width: w * 0.25, height: h * 0.29).scaleEffect(x: -1, y: 1).offset(x: -w * 0.15, y: -h * 0.04)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
