import Foundation
import Darwin

/// ผลการวัด 1 ครั้งจาก NTP server (RFC 5905: ใช้ timestamp ทั้ง 4 ค่า t1..t4)
struct NTPSample: Sendable {
    let host: String
    let address: String
    let version: Int
    let stratum: Int
    let leap: Int
    let poll: Int
    let precision: Int
    let rootDelay: Double       // วินาที
    let rootDispersion: Double  // วินาที
    let refID: String
    let t1: Double, t2: Double, t3: Double, t4: Double

    /// เวลา server ลบเวลาเครื่องนี้ (วินาที) — บวก = server เร็วกว่าเครื่องนี้
    var offset: Double { ((t2 - t1) + (t3 - t4)) / 2 }
    /// round-trip delay (วินาที)
    var delay: Double { (t4 - t1) - (t3 - t2) }
}

/// สรุปผลจากหลายตัวอย่าง (median ของ offset และ delay เหมือนโปรแกรมเดิม)
struct NTPSummary: Sendable {
    let last: NTPSample
    let offset: Double
    let delay: Double
    let okCount: Int
    let requested: Int
    let sampleErrors: [String]
    /// เวลาของ server โดยประมาณ ณ ตอนได้รับคำตอบล่าสุด
    var serverTime: Date { Date(timeIntervalSince1970: last.t4 + offset) }
}

struct NTPError: Error, LocalizedError, Sendable {
    let message: String
    var fatal = false
    var errorDescription: String? { message }
}

enum AddressFamily: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto", ipv4 = "IPv4", ipv6 = "IPv6"
    var id: String { rawValue }
    var value: Int32 { switch self { case .auto: AF_UNSPEC; case .ipv4: AF_INET; case .ipv6: AF_INET6 } }
}

struct NTPOptions: Sendable {
    var version = 4
    var family = AddressFamily.auto
    var timeout = 2.5
    var samples = 3
}

enum NTPClient {
    static let ntpEpochOffset: Double = 2_208_988_800 // 1900 → 1970
    /// ระยะห่างระหว่างตัวอย่าง (เดิม 0.12 วินาที ซึ่งถี่จนเสี่ยงโดน rate-limit / Kiss-o'-Death)
    static let sampleSpacing: Double = 0.5

    /// วัดหลายตัวอย่างบน background thread — ไม่บล็อก UI
    static func measure(host: String, options: NTPOptions) async -> Result<NTPSummary, NTPError> {
        await Task.detached(priority: .userInitiated) {
            var samples: [NTPSample] = []
            var errors: [String] = []
            let n = max(1, options.samples)
            for i in 0..<n {
                if Task.isCancelled { break }
                do {
                    samples.append(try query(host: host, options: options))
                } catch let e as NTPError {
                    errors.append(e.message)
                    // DNS ล้มเหลว / host ว่าง: ลองซ้ำก็ไม่มีประโยชน์
                    if samples.isEmpty && e.fatal { break }
                } catch {
                    errors.append(error.localizedDescription)
                }
                if i < n - 1 { try? await Task.sleep(for: .seconds(sampleSpacing)) }
            }
            guard let last = samples.last else {
                let unique = Array(NSOrderedSet(array: errors)) as? [String] ?? errors
                return .failure(NTPError(message: unique.joined(separator: "\n")))
            }
            return .success(NTPSummary(last: last,
                                       offset: median(samples.map(\.offset)),
                                       delay: median(samples.map(\.delay)),
                                       okCount: samples.count, requested: n, sampleErrors: errors))
        }.value
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// คิวรี 1 ครั้งแบบ blocking — ห้ามเรียกบน main thread
    static func query(host rawHost: String, options: NTPOptions) throws -> NTPSample {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw NTPError(message: "กรุณาระบุชื่อหรือ IP ของเซิร์ฟเวอร์", fatal: true) }
        guard options.version == 3 || options.version == 4 else { throw NTPError(message: "NTP version ต้องเป็น 3 หรือ 4", fatal: true) }

        var hints = addrinfo()
        hints.ai_family = options.family.value
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, "123", &hints, &list)
        guard rc == 0, let first = list else {
            throw NTPError(message: "ค้นหา DNS ของ \(host) ไม่สำเร็จ (\(options.family.rawValue)): \(String(cString: gai_strerror(rc)))", fatal: true)
        }
        defer { freeaddrinfo(first) }

        var lastError = NTPError(message: options.family == .ipv6
                                 ? "ไม่พบที่อยู่ IPv6 ของ \(host) (หรือเครื่องนี้ไม่มีการเชื่อมต่อ IPv6)"
                                 : "ไม่พบที่อยู่ของ \(host)", fatal: true)
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            let addr = numericHost(ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            // macOS อาจคืนที่อยู่ IPv4-mapped (::ffff:a.b.c.d) เมื่อขอ IPv6 — นั่นไม่ใช่ IPv6 จริง
            if options.family == .ipv6 && addr.lowercased().hasPrefix("::ffff:") && addr.contains(".") { continue }
            do {
                return try exchange(ai: ai.pointee, host: host, address: addr, options: options)
            } catch let e as NTPError {
                lastError = e
            }
        }
        throw lastError
    }

    private static func exchange(ai: addrinfo, host: String, address: String, options: NTPOptions) throws -> NTPSample {
        let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
        guard fd >= 0 else { throw NTPError(message: "สร้าง socket ไม่ได้: \(errnoString())") }
        defer { close(fd) }

        // คำขอ: LI=0, VN=3/4, Mode=3 (client); transmit timestamp เป็นค่าสุ่ม (nonce)
        // server ต้องสะท้อนค่านี้กลับมาใน originate timestamp จึงจะยอมรับคำตอบ
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = UInt8((0 << 6) | (options.version << 3) | 3)
        var nonce = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&nonce, 8)
        packet.replaceSubrange(40..<48, with: nonce)

        let t1 = now()
        let sent = packet.withUnsafeBytes { sendto(fd, $0.baseAddress, 48, 0, ai.ai_addr, ai.ai_addrlen) }
        guard sent == 48 else { throw NTPError(message: "ส่งคำขอไปยัง \(address) ไม่สำเร็จ: \(errnoString())") }

        let deadline = Date().addingTimeInterval(options.timeout)
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw timeoutError(address, options.timeout) }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
            if pr == 0 { throw timeoutError(address, options.timeout) }
            if pr < 0 {
                if errno == EINTR { continue }
                throw NTPError(message: "ข้อผิดพลาดเครือข่าย (\(address)): \(errnoString())")
            }
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 1024, 0) }
            let t4 = now()
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw NTPError(message: "ข้อผิดพลาดเครือข่าย (\(address)): \(errnoString())")
            }
            if n < 48 { throw NTPError(message: "คำตอบจาก \(address) ไม่ครบ (\(n) ไบต์ ต้องมีอย่างน้อย 48)") }
            guard Array(buf[24..<32]) == nonce else { continue } // ไม่ใช่คำตอบของคำขอนี้ — ข้าม
            return try parse(Array(buf[0..<n]), t1: t1, t4: t4, host: host, address: address)
        }
    }

    private static func parse(_ d: [UInt8], t1: Double, t4: Double, host: String, address: String) throws -> NTPSample {
        let leap = Int(d[0] >> 6), vn = Int((d[0] >> 3) & 7), mode = Int(d[0] & 7)
        let stratum = Int(d[1])
        let poll = Int(Int8(bitPattern: d[2]))
        let precision = Int(Int8(bitPattern: d[3]))
        func u32(_ i: Int) -> UInt32 {
            UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
        }
        func ts(_ i: Int) -> Double { Double(u32(i)) - ntpEpochOffset + Double(u32(i + 4)) / 4_294_967_296 }

        let refBytes = Array(d[12..<16])
        let refAscii = String(decoding: refBytes.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        guard mode == 4 else { throw NTPError(message: "คำตอบจาก \(address) มี mode=\(mode) (ต้องเป็น 4 = server)") }
        if stratum == 0 {
            throw NTPError(message: "\(address) ปฏิเสธคำขอ (Kiss-o'-Death \"\(refAscii)\")"
                           + (refAscii == "RATE" ? " — ถามถี่เกินไป ลองลดจำนวนตัวอย่างหรือเพิ่มช่วงเวลา" : ""))
        }
        if stratum > 15 { throw NTPError(message: "\(address) ตอบ stratum \(stratum) (ไม่ซิงค์)") }
        if leap == 3 { throw NTPError(message: "\(address) ยังไม่ได้ซิงค์เวลา (Leap = 3 / unsync)") }
        if u32(40) == 0 && u32(44) == 0 { throw NTPError(message: "transmit timestamp จาก \(address) เป็นศูนย์") }
        if u32(32) == 0 && u32(36) == 0 { throw NTPError(message: "receive timestamp จาก \(address) เป็นศูนย์") }

        let refID: String
        if stratum == 1 { refID = refAscii.isEmpty ? refBytes.map(String.init).joined(separator: ".") : refAscii }
        else if address.contains(":") { refID = refBytes.map { String(format: "%02x", $0) }.joined() } // IPv6: hash ของที่อยู่
        else { refID = refBytes.map(String.init).joined(separator: ".") }

        return NTPSample(host: host, address: address, version: vn, stratum: stratum, leap: leap,
                         poll: poll, precision: precision,
                         rootDelay: Double(u32(4)) / 65536, rootDispersion: Double(u32(8)) / 65536,
                         refID: refID, t1: t1, t2: ts(32), t3: ts(40), t4: t4)
    }

    private static func now() -> Double {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    private static func timeoutError(_ address: String, _ timeout: Double) -> NTPError {
        NTPError(message: "หมดเวลารอคำตอบจาก \(address) (\(String(format: "%g", timeout)) วินาที) — เซิร์ฟเวอร์อาจเข้าถึงไม่ได้จากเครือข่ายนี้")
    }

    private static func errnoString() -> String { String(cString: strerror(errno)) }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t) -> String {
        guard let sa else { return "?" }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return "?" }
        return String(cString: buf)
    }
}
