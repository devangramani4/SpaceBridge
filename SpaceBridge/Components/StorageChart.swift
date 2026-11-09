import Charts
import SwiftUI

/// Donut chart of storage categories. Clicking a sector calls `onSelect`.
struct CategoryDonutChart: View {
    var usages: [CategoryUsage]
    var centerTitle: String
    var centerValue: String
    var onSelect: (StorageCategory) -> Void

    @State private var hovered: StorageCategory?
    private let innerRatio = 0.62

    var body: some View {
        Chart(usages) { usage in
            SectorMark(angle: .value("Size", Double(usage.bytes)), innerRadius: .ratio(innerRatio), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(usage.category.color)
                .opacity(hovered == nil || hovered == usage.category ? 1 : 0.4)
                .accessibilityLabel(usage.category.displayName)
                .accessibilityValue(ByteFormatter.string(usage.bytes))
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    VStack(spacing: 2) {
                        Text(hovered?.displayName ?? centerTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(hovered.flatMap { category in usages.first { $0.category == category } }.map { ByteFormatter.string($0.bytes) } ?? centerValue)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: frame.width * innerRatio * 0.9)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = category(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        if let category = category(at: location, proxy: proxy, geometry: geometry) {
                            onSelect(category)
                        }
                    }
            }
        }
    }

    /// Maps a point to the sector under it. Sectors start at 12 o'clock and run clockwise in data order.
    private func category(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> StorageCategory? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        let dx = point.x - frame.midX
        let dy = point.y - frame.midY
        let radius = (dx * dx + dy * dy).squareRoot()
        let outer = min(frame.width, frame.height) / 2
        guard radius <= outer, radius >= outer * innerRatio * 0.95 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let target = Double(angle / (2 * .pi))
        let total = usages.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for usage in usages {
            cumulative += Double(usage.bytes) / total
            if target <= cumulative { return usage.category }
        }
        return usages.last?.category
    }
}

struct SizeBarItem: Identifiable, Hashable {
    var id: String
    var label: String
    var bytes: Int64
    var color: Color
}

/// Horizontal bar chart of sizes. Clicking a bar calls `onSelect`.
struct SizeBarChart: View {
    var items: [SizeBarItem]
    var onSelect: ((SizeBarItem) -> Void)?

    var body: some View {
        let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Chart(items) { item in
            BarMark(x: .value("Size", Double(item.bytes)), y: .value("Item", item.id))
                .foregroundStyle(item.color.gradient)
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(ByteFormatter.string(item.bytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityLabel(item.label)
                .accessibilityValue(ByteFormatter.string(item.bytes))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let id = value.as(String.self) {
                        Text(lookup[id]?.label ?? id).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .trailing)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(ByteFormatter.string(Int64(bytes))) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let onSelect, let anchor = proxy.plotFrame else { return }
                        let origin = geometry[anchor].origin
                        if let id: String = proxy.value(atY: location.y - origin.y), let item = lookup[id] {
                            onSelect(item)
                        }
                    }
            }
        }
        .frame(height: max(CGFloat(items.count) * 26 + 36, 80))
    }
}

struct ChartPoint: Identifiable, Hashable {
    var date: Date
    var value: Double
    var series: String
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

/// Stacked area chart for live monitors.
struct LiveAreaChart: View {
    var points: [ChartPoint]
    var seriesColors: KeyValuePairs<String, Color>
    var yDomain: ClosedRange<Double>
    var valueLabel: (Double) -> String

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value), stacking: .standard)
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(seriesColors)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(valueLabel(number)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .animation(.linear(duration: 0.2), value: points.count)
    }
}

/// Line chart of disk usage history from completed scans.
struct StorageTrendChart: View {
    var history: [StorageHistoryPoint]

    var body: some View {
        Chart(history) { point in
            LineMark(x: .value("Date", point.date), y: .value("Used", Double(point.volumeUsed)))
                .interpolationMethod(.monotone)
                .symbol(.circle)
            AreaMark(x: .value("Date", point.date), y: .value("Used", Double(point.volumeUsed)))
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let bytes = value.as(Double.self) { Text(ByteFormatter.string(Int64(bytes))) } }
            }
        }
    }
}
