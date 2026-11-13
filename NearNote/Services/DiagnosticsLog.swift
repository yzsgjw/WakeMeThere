import Foundation

/// 到站链路的一本流水账。
///
/// 真机上没有控制台：出了“明明到站了却不响”的问题，只能靠应用自己把关键节点写下来。
/// 这里记的是**判定过程**（围栏注册了几个、资格判定被谁挡下、复核算出多少米、通知发没发出去），
/// 不记任何位置历史以外的隐私内容。日志同时落盘到 Documents/diagnostics.log，重启后还能看。
@MainActor
public final class DiagnosticsLog: ObservableObject {
    public static let shared = DiagnosticsLog()

    public struct Entry: Identifiable, Hashable {
        public let id: Int
        public let time: String
        public let tag: String
        public let message: String

        public var text: String { "\(time) [\(tag)] \(message)" }
    }

    @Published public private(set) var entries: [Entry] = []

    private let capacity = 400
    private var nextID = 1
    private let fileURL: URL
    private let stamp: DateFormatter

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("diagnostics.log")
        stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm:ss"
        loadTail()
    }

    public func record(_ message: String, tag: String = "应用") {
        let entry = Entry(id: nextID, time: stamp.string(from: Date()), tag: tag, message: message)
        nextID += 1
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        appendToFile("\(entry.time) [\(entry.tag)] \(entry.message)\n")
    }

    public var plainText: String {
        entries.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func appendToFile(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadTail() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").suffix(200) {
            let raw = String(line)
            guard let close = raw.firstIndex(of: "]"), let open = raw.firstIndex(of: "[") else { continue }
            let time = String(raw[raw.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            let tag = String(raw[raw.index(after: open)..<close])
            let message = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            entries.append(Entry(id: nextID, time: time, tag: tag, message: message))
            nextID += 1
        }
    }
}
