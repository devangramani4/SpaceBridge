import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let memory = model.monitor.memory {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(title: "Total RAM", value: ByteFormatter.string(memory.total), detail: nil, systemImage: "memorychip")
                        MetricCard(title: "Used", value: ByteFormatter.string(memory.used), detail: "App + Wired + Compressed", systemImage: "chart.pie.fill", tint: .orange)
                        MetricCard(title: "Available", value: ByteFormatter.string(memory.available), detail: "Free + cached files macOS can reclaim", systemImage: "checkmark.circle", tint: .green)
                        MetricCard(title: "App Memory", value: ByteFormatter.string(memory.app), detail: nil, systemImage: "square.grid.2x2", tint: .blue)
                        MetricCard(title: "Wired", value: ByteFormatter.string(memory.wired), detail: "Kernel memory; can't be compressed or swapped", systemImage: "lock", tint: .red)
                        MetricCard(title: "Compressed", value: ByteFormatter.string(memory.compressed), detail: nil, systemImage: "rectangle.compress.vertical", tint: .purple)
                        MetricCard(title: "Cached Files", value: ByteFormatter.string(memory.cached), detail: nil, systemImage: "doc.on.doc", tint: .teal)
                        MetricCard(title: "Swap Used", value: memory.swapUsed.map { ByteFormatter.string($0) } ?? "Unavailable",
                                   detail: memory.swapTotal.map { "of \(ByteFormatter.string($0)) swap files" }, systemImage: "arrow.left.arrow.right", tint: .gray)
                        MetricCard(title: "Swap Available", value: memory.swapAvailable.map { ByteFormatter.string($0) } ?? "Unavailable",
                                   detail: "macOS grows swap as needed", systemImage: "externaldrive", tint: .gray)
                    }
                    SectionCard("Memory Pressure", systemImage: "gauge.with.dots.needle.50percent") {
                        PressureMeter(fraction: memory.pressureFraction, label: memory.pressure.rawValue, tint: tint(for: memory.pressure))
                        Text((memory.systemFreePercent.map { "macOS reports \($0)% of memory available. " } ?? "") +
                             "Pressure is the kernel's own assessment: it stays Normal even when RAM looks “full” because macOS uses spare memory for caches.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SectionCard("Live Usage", systemImage: "waveform.path.ecg") {
                        LiveAreaChart(points: points, seriesColors: ["Wired": .red, "App": .blue, "Compressed": .purple],
                                      yDomain: 0...Double(memory.total), valueLabel: { ByteFormatter.string(Int64($0)) })
                            .frame(height: 220)
                    }
                    SectionCard("Top Memory Users", systemImage: "list.number") {
                        TopProcessesList(processes: model.monitor.processes.sorted { $0.memorySortKey > $1.memorySortKey }.prefix(10).map { $0 },
                                         value: { $0.memoryBytes.map { ByteFormatter.string($0) } ?? "Restricted" })
                    }
                } else {
                    ProgressView("Reading memory statistics…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .navigationTitle("Memory")
        .onAppear { model.monitor.subscribe(processes: true); Task { await model.monitor.tick() } }
        .onDisappear { model.monitor.unsubscribe(processes: true) }
    }

    private var points: [ChartPoint] {
        model.monitor.memoryHistory.flatMap { sample in
            [ChartPoint(date: sample.date, value: Double(sample.wired), series: "Wired"),
             ChartPoint(date: sample.date, value: Double(sample.app), series: "App"),
             ChartPoint(date: sample.date, value: Double(sample.compressed), series: "Compressed")]
        }
    }

    private func tint(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}

struct TopProcessesList: View {
    var processes: [ProcessSnapshot]
    var value: (ProcessSnapshot) -> String

    var body: some View {
        if processes.isEmpty {
            Text("Collecting process data…").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(processes) { process in
                    HStack {
                        ProcessIcon(process: process)
                        Text(process.name).lineLimit(1)
                        Text("PID \(process.pid)").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(value(process)).monospacedDigit()
                    }
                }
            }
        }
    }
}
