import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

enum ServerState {
    case idle, running
    case success(NTPSummary)
    case failure(String)
    var summary: NTPSummary? { if case .success(let s) = self { return s }; return nil }
    var isRunning: Bool { if case .running = self { return true }; return false }
}

struct LogEntry: Identifiable {
    enum Kind { case info, ok, warn, err }
    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

enum CheckStatus: Equatable {
    case ready, checking, success, partial, error
    var text: String {
        switch self {
        case .ready: "พร้อม"
        case .checking: "กำลังเช็ค…"
        case .success: "สำเร็จ"
        case .partial: "สำเร็จบางส่วน"
        case .error: "ผิดพลาด"
        }
    }
    var color: Color {
        switch self {
        case .ready: .secondary
        case .checking: .accentColor
        case .success: .green
        case .partial: .orange
        case .error: .red
        }
    }
}

@MainActor @Observable
final class Model {
    private let d = UserDefaults.standard

    // ---- การตั้งค่า (จำค่าไว้ระหว่างการเปิดโปรแกรม)
    var targetHost: String { didSet { d.set(targetHost, forKey: "targetHost") } }
    var referenceHost: String { didSet { d.set(referenceHost, forKey: "referenceHost") } }
    var version: Int { didSet { d.set(version, forKey: "version") } }
    var family: AddressFamily { didSet { d.set(family.rawValue, forKey: "family") } }
    var timeout: Double { didSet { d.set(timeout, forKey: "timeout") } }
    var samples: Int { didSet { d.set(samples, forKey: "samples") } }
    var threshold: Double { didSet { d.set(threshold, forKey: "threshold") } }
    var interval: Double { didSet { d.set(interval, forKey: "interval") } }
    var auto = false { didSet { updateAuto() } }

    // ---- ผลลัพธ์
    var targetState: ServerState = .idle
    var referenceState: ServerState = .idle
    var status: CheckStatus = .ready
    var log: [LogEntry] = []
    var lastCheck: Date?
    var lastTargetHost = ""
    var lastReferenceHost = ""
    var lastThreshold = 100.0
    private var autoTask: Task<Void, Never>?

    static let timeoutRange = 0.2...30.0
    static let samplesRange = 1...20
    static let intervalRange = 2.0...3600.0

    init() {
        targetHost = d.string(forKey: "targetHost") ?? "pool.ntp.org"
        referenceHost = d.string(forKey: "referenceHost") ?? "time.google.com"
        version = d.object(forKey: "version") as? Int ?? 4
        family = AddressFamily(rawValue: d.string(forKey: "family") ?? "") ?? .auto
        timeout = d.object(forKey: "timeout") as? Double ?? 2.5
        samples = d.object(forKey: "samples") as? Int ?? 3
        threshold = d.object(forKey: "threshold") as? Double ?? 100
        interval = d.object(forKey: "interval") as? Double ?? 5
        append(.info, "เริ่มบันทึก log")
    }

    var isChecking: Bool { status == .checking }

    var deltaMs: Double? {
        guard let a = targetState.summary, let b = referenceState.summary else { return nil }
        return (a.offset - b.offset) * 1000
    }
    var passed: Bool? { deltaMs.map { abs($0) <= lastThreshold } }

    private var options: NTPOptions {
        NTPOptions(version: version == 3 ? 3 : 4, family: family,
                   timeout: timeout.clamped(to: Self.timeoutRange),
                   samples: samples.clamped(to: Self.samplesRange))
    }

    func checkNow() { Task { await check() } }

    /// เช็คทั้งสอง server พร้อมกัน (งานเครือข่ายอยู่นอก main thread)
    func check() async {
        guard !isChecking else { return }
        // ค่าที่ผู้ใช้กรอกผิดช่วงจะถูกปรับให้อยู่ในช่วงที่ใช้ได้
        timeout = timeout.clamped(to: Self.timeoutRange)
        samples = samples.clamped(to: Self.samplesRange)
        threshold = max(0, threshold)
        let opts = options
        let tHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let rHost = referenceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let thr = threshold

        status = .checking
        targetState = .running
        referenceState = .running

        async let a = NTPClient.measure(host: tHost, options: opts)
        async let b = NTPClient.measure(host: rHost, options: opts)
        let (ra, rb) = await (a, b)

        lastTargetHost = tHost
        lastReferenceHost = rHost
        lastThreshold = thr
        lastCheck = Date()
        targetState = Self.state(ra)
        referenceState = Self.state(rb)

        for (label, r) in [("เป้าหมาย", ra), ("อ้างอิง", rb)] {
            if case .success(let s) = r, !s.sampleErrors.isEmpty {
                append(.warn, "\(label): สำเร็จ \(s.okCount)/\(s.requested) ตัวอย่าง — \(s.sampleErrors.last ?? "")")
            }
        }

        if let t = targetState.summary, let g = referenceState.summary, let dms = deltaMs {
            let ok = abs(dms) <= thr
            append(ok ? .ok : .warn,
                   String(format: "Δ=%+.3f ms (%@) | เป้าหมาย off=%+.3f ms | อ้างอิง off=%+.3f ms | thr=%.1f ms",
                          dms, ok ? "PASS" : "FAIL", t.offset * 1000, g.offset * 1000, thr))
            status = .success
        } else {
            var errs: [String] = []
            if case .failure(let m) = targetState { errs.append("เป้าหมาย (\(tHost)): \(m)") }
            if case .failure(let m) = referenceState { errs.append("อ้างอิง (\(rHost)): \(m)") }
            append(.err, errs.joined(separator: " | ").replacingOccurrences(of: "\n", with: "; "))
            status = (targetState.summary != nil || referenceState.summary != nil) ? .partial : .error
        }
    }

    private static func state(_ r: Result<NTPSummary, NTPError>) -> ServerState {
        switch r {
        case .success(let s): .success(s)
        case .failure(let e): .failure(e.message)
        }
    }

    private func updateAuto() {
        autoTask?.cancel()
        autoTask = nil
        guard auto else { return }
        append(.info, "เปิดโหมด Auto")
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                let secs = self.interval.clamped(to: Self.intervalRange)
                try? await Task.sleep(for: .seconds(secs))
            }
        }
    }

    func append(_ kind: LogEntry.Kind, _ text: String) {
        log.append(LogEntry(date: Date(), kind: kind, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func clearLog() { log.removeAll(); append(.info, "ล้าง log แล้ว") }

    // ---- Export CSV
    var canExport: Bool { targetState.summary != nil || referenceState.summary != nil }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ntp_check_\(Fmt.fileStamp.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // BOM เพื่อให้ Excel แสดงภาษาไทย/Δ ได้ถูกต้อง
            try ("\u{FEFF}" + csvText()).write(to: url, atomically: true, encoding: .utf8)
            append(.info, "Export CSV: \(url.path)")
            let alert = NSAlert()
            alert.messageText = "Export CSV"
            alert.informativeText = "บันทึกแล้ว: \(url.path)"
            alert.runModal()
        } catch {
            append(.err, "Export CSV ผิดพลาด: \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            alert.messageText = "ผิดพลาดในการบันทึก"
            alert.runModal()
        }
    }

    func csvText() -> String {
        func q(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        func row(_ cols: [String]) -> String { cols.map(q).joined(separator: ",") }
        func f3(_ v: Double) -> String { String(format: "%.3f", v) }
        func server(_ section: String, _ host: String, _ st: ServerState) -> String {
            switch st {
            case .success(let s):
                let l = s.last
                return row([section, host, l.address, "\(l.stratum)", "\(l.leap)", l.refID,
                            f3(l.rootDelay * 1000), f3(l.rootDispersion * 1000), "\(l.precision)",
                            f3(s.delay * 1000), f3(s.offset * 1000),
                            Fmt.full(s.serverTime, tz: Fmt.bangkok), Fmt.full(s.serverTime, tz: Fmt.utc),
                            "\(s.okCount)/\(s.requested)", ""])
            case .failure(let m):
                return row([section, host] + Array(repeating: "", count: 12) + [m.replacingOccurrences(of: "\n", with: "; ")])
            default:
                return row([section, host] + Array(repeating: "", count: 13))
            }
        }
        var lines: [String] = []
        lines.append(row(["Generated", Fmt.full(Date(), tz: Fmt.bangkok)]))
        lines.append("")
        if let dms = deltaMs {
            lines.append(row(["Δ (target - reference) ms", f3(dms), "Threshold ms", String(format: "%.1f", lastThreshold),
                              passed == true ? "PASS" : "FAIL"]))
        } else {
            lines.append(row(["Δ (target - reference) ms", "-"]))
        }
        lines.append("")
        lines.append(row(["Section", "Host", "Addr", "Stratum", "Leap", "RefID", "Root Delay (ms)", "Root Dispersion (ms)",
                          "Precision (2^x s)", "Delay (ms)", "Offset (ms)", "Server time (Asia/Bangkok)", "Server time (UTC)",
                          "Samples OK", "Error"]))
        lines.append(server("Target", lastTargetHost, targetState))
        lines.append(server("Reference", lastReferenceHost, referenceState))
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Formatting

enum Fmt {
    static let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    static let utc = TimeZone(identifier: "UTC")!

    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    @MainActor static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let key = pattern + tz.identifier
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = pattern
        cache[key] = f
        return f
    }
    @MainActor static func full(_ d: Date, tz: TimeZone) -> String { formatter("yyyy-MM-dd HH:mm:ss.SSS", tz).string(from: d) }
    @MainActor static func time(_ d: Date, tz: TimeZone = bangkok) -> String { formatter("HH:mm:ss.SSS", tz).string(from: d) }
    @MainActor static func clock(_ d: Date) -> String { formatter("HH:mm:ss", bangkok).string(from: d) }
    @MainActor static var fileStamp: DateFormatter { formatter("yyyyMMdd_HHmmss", bangkok) }
    static func ms(_ v: Double, signed: Bool = true) -> String { String(format: signed ? "%+.3f ms" : "%.3f ms", v) }
}

// MARK: - Root view

struct ContentView: View {
    let model: Model

    var body: some View {
        HSplitView {
            SettingsPane(model: model)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            ResultsPane(model: model)
                .frame(minWidth: 560)
        }
        .frame(minWidth: 900, minHeight: 620)
        // เปิดโปรแกรมแล้วเช็คทันที เมื่อรันด้วย: open "NTP Checker.app" --args -checkOnLaunch YES
        .task { if UserDefaults.standard.bool(forKey: "checkOnLaunch") { await model.check() } }
    }
}

// MARK: - Settings (left pane)

struct SettingsPane: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("เซิร์ฟเวอร์") {
                    LabeledContent("NTP Server (ทดสอบ)") {
                        TextField("", text: $model.targetHost, prompt: Text("host หรือ IP"))
                            .onSubmit { model.checkNow() }
                    }
                    LabeledContent("Reference (อ้างอิง)") {
                        TextField("", text: $model.referenceHost, prompt: Text("host หรือ IP"))
                            .onSubmit { model.checkNow() }
                    }
                }
                Section("ตัวเลือกการวัด") {
                    Picker("NTP version", selection: $model.version) {
                        Text("v4").tag(4); Text("v3").tag(3)
                    }.pickerStyle(.segmented)
                    Picker("Address family", selection: $model.family) {
                        ForEach(AddressFamily.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    numberRow("Timeout (วินาที)", value: $model.timeout, step: 0.5, range: Model.timeoutRange)
                    LabeledContent("Samples (ครั้ง)") {
                        HStack(spacing: 4) {
                            TextField("", value: $model.samples, format: .number).frame(width: 56).multilineTextAlignment(.trailing)
                            Stepper("", value: $model.samples, in: Model.samplesRange).labelsHidden()
                        }
                    }
                    numberRow("Threshold |Δ| (ms)", value: $model.threshold, step: 10, range: 0...100_000)
                }
                Section("อัตโนมัติ") {
                    Toggle("Auto (เช็คซ้ำอัตโนมัติ)", isOn: $model.auto).toggleStyle(.switch)
                    numberRow("ทุก ๆ (วินาที)", value: $model.interval, step: 1, range: Model.intervalRange)
                }
            }
            .formStyle(.grouped)

            VStack(spacing: 8) {
                Button { model.checkNow() } label: {
                    Label(model.isChecking ? "กำลังเช็ค…" : "เช็คตอนนี้", systemImage: "bolt.horizontal.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isChecking)

                Button { model.exportCSV() } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.canExport)

                Text("© NTP checker — UDP/123").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>, step: Double, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 72).multilineTextAlignment(.trailing)
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
        }
    }
}

// MARK: - Results (right pane)

struct ResultsPane: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            VSplitView {
                HSplitView {
                    ResultCard(title: "ผลลัพธ์: NTP Server (ทดสอบ)", icon: "server.rack",
                               host: model.lastTargetHost, state: model.targetState)
                        .frame(minWidth: 270)
                    ResultCard(title: "ผลลัพธ์: Reference (อ้างอิง)", icon: "globe.asia.australia",
                               host: model.lastReferenceHost, state: model.referenceState)
                        .frame(minWidth: 270)
                }
                .frame(minHeight: 300, idealHeight: 480, maxHeight: .infinity)
                .layoutPriority(1)
                LogView(model: model)
                    .frame(minHeight: 100, idealHeight: 150, maxHeight: 400)
            }
        }
        .background(.background)
    }
}

struct HeaderBar: View {
    @Bindable var model: Model

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 1) {
                    Text("เวลาท้องถิ่น (ไทย)").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.clock(ctx.date)).font(.system(.title3, design: .rounded).monospacedDigit().weight(.medium))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("สถานะ").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if model.isChecking { ProgressView().controlSize(.small) }
                    else { Circle().fill(model.status.color).frame(width: 8, height: 8) }
                    Text(model.status.text).font(.headline)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Δ (เป้าหมาย − อ้างอิง)").font(.caption).foregroundStyle(.secondary)
                Text(model.deltaMs.map { Fmt.ms($0) } ?? "– ms")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(passColor)
            }
            passBadge
        }
    }

    private var passColor: Color {
        switch model.passed { case true?: .green; case false?: .red; case nil: .secondary }
    }

    private var passBadge: some View {
        let text: String = switch model.passed { case true?: "PASS"; case false?: "FAIL"; case nil: "PASS/FAIL" }
        return VStack(spacing: 2) {
            Text(text).font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(model.passed == nil ? Color.secondary : Color.white)
            Text(String(format: "|Δ| ≤ %.1f ms", model.lastThreshold)).font(.caption2)
                .foregroundStyle(model.passed == nil ? Color.secondary : Color.white.opacity(0.9))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(model.passed == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(passColor.gradient),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ResultCard: View {
    let title: String
    let icon: String
    let host: String
    let state: ServerState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(title, systemImage: icon).font(.headline)
                    Spacer()
                    switch state {
                    case .success(let s) where s.okCount < s.requested:
                        Image(systemName: "checkmark.circle.trianglebadge.exclamationmark").foregroundStyle(.orange)
                            .help("สำเร็จ \(s.okCount)/\(s.requested) ตัวอย่าง")
                    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    case .running: ProgressView().controlSize(.small)
                    case .idle: EmptyView()
                    }
                }
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.7)))
            .padding(10)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            Text("ยังไม่ได้เช็ค — กด “เช็คตอนนี้”").foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 120)
        case .running:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("กำลังติดต่อเซิร์ฟเวอร์…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failure(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label("ติดต่อ \(host.isEmpty ? "เซิร์ฟเวอร์" : host) ไม่สำเร็จ", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.subheadline.weight(.semibold))
                Text(msg).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .success(let s):
            details(s)
        }
    }

    private func details(_ s: NTPSummary) -> some View {
        let l = s.last
        return VStack(alignment: .leading, spacing: 10) {
            // เวลาของ server เดินต่อเนื่อง (นาฬิกาเครื่องนี้ + offset ที่วัดได้)
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let t = ctx.date.addingTimeInterval(s.offset)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.time(t)).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("เวลาไทยของเซิร์ฟเวอร์ (ประมาณ) · UTC \(Fmt.time(t, tz: Fmt.utc))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Host/Addr", "\(l.host) / \(l.address)")
                row("Offset", Fmt.ms(s.offset * 1000), strong: true)
                row("Delay / RTT", Fmt.ms(s.delay * 1000, signed: false), strong: true)
                row("Stratum", "\(l.stratum)")
                row("Leap", "\(l.leap) (\(l.leap == 3 ? "unsync" : "ok"))")
                row("RefID", l.refID)
                row("Root Delay", Fmt.ms(l.rootDelay * 1000, signed: false))
                row("Root Dispersion", Fmt.ms(l.rootDispersion * 1000, signed: false))
                row("Precision", "2^\(l.precision) s (≈ \(precisionText(l.precision)))")
                row("Server time (est.)", Fmt.full(s.serverTime, tz: Fmt.bangkok) + " (ไทย)")
                row("", Fmt.full(s.serverTime, tz: Fmt.utc) + " (UTC)")
                row("ตัวอย่าง", "สำเร็จ \(s.okCount)/\(s.requested) · NTP v\(l.version) · median")
            }
            .font(.callout)
            if !s.sampleErrors.isEmpty {
                Text("บางตัวอย่างล้มเหลว: \(s.sampleErrors.last ?? "")")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func precisionText(_ p: Int) -> String {
        let v = pow(2.0, Double(p))
        if v >= 1 { return String(format: "%g s", v) }
        if v >= 1e-3 { return String(format: "%.3g ms", v * 1e3) }
        if v >= 1e-6 { return String(format: "%.3g µs", v * 1e6) }
        return String(format: "%.3g ns", v * 1e9)
    }

    private func row(_ k: String, _ v: String, strong: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
                .fontWeight(strong ? .semibold : .regular)
                .gridColumnAlignment(.leading)
        }
    }
}

struct LogView: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Log", systemImage: "text.alignleft").font(.subheadline.weight(.semibold))
                Spacer()
                Button("คัดลอก") {
                    let text = model.log.map { "\(Fmt.full($0.date, tz: Fmt.bangkok)) \(tag($0.kind)) \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.borderless)
                Button("ล้าง") { model.clearLog() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.clock(e.date)).foregroundStyle(.secondary)
                                Text(tag(e.kind)).foregroundStyle(color(e.kind)).fontWeight(.semibold)
                                Text(e.text).textSelection(.enabled)
                            }
                            .id(e.id)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.count) {
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.background.secondary)
    }

    private func tag(_ k: LogEntry.Kind) -> String {
        switch k { case .info: "[INFO]"; case .ok: "[OK]"; case .warn: "[WARN]"; case .err: "[ERR]" }
    }
    private func color(_ k: LogEntry.Kind) -> Color {
        switch k { case .info: .secondary; case .ok: .green; case .warn: .orange; case .err: .red }
    }
}

// MARK: - App

@main
struct NTPCheckerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // สร้างครั้งเดียวตลอดอายุโปรแกรม (CommandLineTools ไม่มี plugin ของมาโคร @State จึงไม่ใช้ @State)
    private let model = Model()

    var body: some Scene {
        Window("NTP Checker — เทียบ NTP Server กับเซิร์ฟเวอร์อ้างอิง", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
