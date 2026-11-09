import Charts
import SwiftUI

struct CPUView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let cpu = model.monitor.cpu {
                    SectionCard("Overall CPU", systemImage: "cpu") {
                        HStack(spacing: 16) {
                            UsageBar(fraction: cpu.total, tint: cpu.total > 0.85 ? .red : .accentColor, height: 14)
                            Text(PercentFormatter.string(cpu.total)).font(.title2.weight(.semibold)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        }
                        if let brand = cpu.brand { Text(brand).font(.caption).foregroundStyle(.secondary) }
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(title: "User", value: PercentFormatter.string(cpu.user), detail: "Apps and user processes", systemImage: "person", tint: .blue)
                        MetricCard(title: "System", value: PercentFormatter.string(cpu.system), detail: "macOS kernel", systemImage: "gearshape", tint: .red)
                        MetricCard(title: "Idle", value: PercentFormatter.string(cpu.idle), detail: nil, systemImage: "moon.zzz", tint: .gray)
                        MetricCard(title: "Cores", value: "\(cpu.logicalCores)", detail: coreDetail(cpu), systemImage: "square.grid.3x3", tint: .purple)
                        MetricCard(title: "Load Average", value: cpu.loadAverage.first.map { String(format: "%.2f", $0) } ?? "—",
                                   detail: cpu.loadAverage.count == 3 ? String(format: "1 min · 5 min %.2f · 15 min %.2f", cpu.loadAverage[1], cpu.loadAverage[2]) : nil,
                                   systemImage: "chart.line.uptrend.xyaxis", tint: .orange)
                    }
                    SectionCard("History", systemImage: "waveform.path.ecg") {
                        LiveAreaChart(points: points, seriesColors: ["System": .red, "User": .blue], yDomain: 0...1,
                                      valueLabel: { PercentFormatter.string($0) })
                            .frame(height: 200)
                    }
                    SectionCard("Per Core", systemImage: "square.grid.3x3.fill") {
                        Chart(Array(cpu.perCore.enumerated()), id: \.offset) { index, value in
                            BarMark(x: .value("Core", "\(index + 1)"), y: .value("Usage", value))
                                .foregroundStyle(value > 0.85 ? Color.red.gradient : Color.accentColor.gradient)
                        }
                        .chartYScale(domain: 0...1)
                        .chartYAxis { AxisMarks(values: [0, 0.5, 1]) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(PercentFormatter.string(v)) } } } }
                        .frame(height: 140)
                    }
                    SectionCard("Top Processes", systemImage: "list.number") {
                        TopProcessesList(processes: model.monitor.processes.sorted { $0.cpuSortKey > $1.cpuSortKey }.prefix(10).map { $0 },
                                         value: { $0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Restricted" })
                        Text("Per-process CPU: 100% = one full core, so busy apps can exceed 100% on multi-core Macs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Measuring CPU usage…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .navigationTitle("CPU")
        .onAppear { model.monitor.subscribe(processes: true); Task { await model.monitor.tick() } }
        .onDisappear { model.monitor.unsubscribe(processes: true) }
    }

    private var points: [ChartPoint] {
        model.monitor.cpuHistory.flatMap { sample in
            [ChartPoint(date: sample.date, value: sample.system, series: "System"),
             ChartPoint(date: sample.date, value: sample.user + sample.nice, series: "User")]
        }
    }

    private func coreDetail(_ cpu: CPUSnapshot) -> String {
        var parts: [String] = []
        if let p = cpu.performanceCores, let e = cpu.efficiencyCores { parts.append("\(p) performance · \(e) efficiency") }
        else if let physical = cpu.physicalCores { parts.append("\(physical) physical") }
        return parts.joined()
    }
}
