import Darwin
import Foundation

final class QuickStartController {
    private let queue = DispatchQueue(label: "dev.nixterm.qemu.quick-start", qos: .userInteractive)
    private let readQueue = DispatchQueue(label: "dev.nixterm.qemu.quick-start.read", qos: .userInteractive)
    private let snapshotURL: URL
    private let temporaryURL: URL
    private let report: (String) -> Void
    private let releaseGuest: () -> Void
    private var descriptor: Int32 = -1
    private var receiveBuffer = Data()
    private var qmpReady = false
    private var barrierReached = false
    private var operationStarted = false
    private var pollCount = 0
    private var operationStartedAt = Date()

    let shouldRestore: Bool

    init?(rootFileSystem: URL, report: @escaping (String) -> Void, releaseGuest: @escaping () -> Void) {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: rootFileSystem.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }

        let name = "nixterm-quickstart-v1-\(size.int64Value)-\(Int(modified.timeIntervalSince1970)).bin"
        snapshotURL = cache.appendingPathComponent(name)
        temporaryURL = snapshotURL.appendingPathExtension("tmp")
        self.report = report
        self.releaseGuest = releaseGuest
        shouldRestore = FileManager.default.fileExists(atPath: snapshotURL.path)

        if let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            for file in files
                where file.lastPathComponent.hasPrefix("nixterm-quickstart-") && file.lastPathComponent != name
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func connect(to port: UInt16) {
        queue.async { [weak self] in
            self?.connectMonitor(to: port)
        }
    }

    func guestReachedBarrier() {
        queue.async { [weak self] in
            guard let self else { return }
            barrierReached = true
            startSaveIfPossible()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func connectMonitor(to port: UInt16) {
        guard let socket = connectSocket(to: port) else {
            fail("QMP control channel unavailable")
            return
        }
        descriptor = socket
        readQueue.async { [weak self] in
            self?.readMonitor(from: socket)
        }
    }

    private func connectSocket(to port: UInt16) -> Int32? {
        for _ in 0 ..< 300 {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            let converted = "127.0.0.1".withCString {
                inet_pton(AF_INET, $0, &address.sin_addr)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if converted == 1, result == 0 {
                return socket
            }
            Darwin.close(socket)
            usleep(100_000)
        }
        return nil
    }

    private func readMonitor(from socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            let data = Data(buffer[0 ..< count])
            queue.async { [weak self] in
                self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if message["QMP"] != nil {
            send("qmp_capabilities", id: "capabilities")
            return
        }
        guard let id = message["id"] as? String else { return }
        if let error = message["error"] as? [String: Any] {
            if id.hasPrefix("continue-") {
                report("Quick start resume warning: \(error["desc"] as? String ?? "QMP command failed").\r\n")
            } else {
                fail(error["desc"] as? String ?? "QMP command failed")
            }
            return
        }

        switch id {
        case "capabilities":
            qmpReady = true
            shouldRestore ? startRestore() : startSaveIfPossible()
        case "stop-save":
            operationStartedAt = Date()
            send("migrate", arguments: ["uri": "file:\(temporaryURL.path)"], id: "save")
        case "save":
            pollMigration(id: "query-save")
        case "restore":
            pollMigration(id: "query-restore")
        case "query-save", "query-restore":
            guard let result = message["return"] as? [String: Any], let status = result["status"] as? String else {
                fail("Invalid migration status")
                return
            }
            if status == "completed" {
                if id == "query-save" {
                    finishSave()
                } else {
                    finishRestore()
                }
            } else if status == "failed" || status == "cancelled" {
                fail(result["error-desc"] as? String ?? "Migration \(status)")
            } else {
                pollMigration(id: id)
            }
        default:
            break
        }
    }

    private func startSaveIfPossible() {
        guard barrierReached, qmpReady, !shouldRestore, !operationStarted else { return }
        operationStarted = true
        pollCount = 0
        try? FileManager.default.removeItem(at: temporaryURL)
        report("Saving quick start snapshot...\r\n")
        send("stop", id: "stop-save")
    }

    private func startRestore() {
        guard !operationStarted else { return }
        operationStarted = true
        operationStartedAt = Date()
        pollCount = 0
        send("migrate-incoming", arguments: ["uri": "file:\(snapshotURL.path)"], id: "restore")
    }

    private func pollMigration(id: String) {
        pollCount += 1
        guard pollCount <= 300 else {
            fail("Migration timed out")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.send("query-migrate", id: id)
        }
    }

    private func finishSave() {
        do {
            try? FileManager.default.removeItem(at: snapshotURL)
            try FileManager.default.moveItem(at: temporaryURL, to: snapshotURL)
        } catch {
            fail(error.localizedDescription)
            return
        }
        report(String(format: "Quick start saved in %.2fs.\r\n", Date().timeIntervalSince(operationStartedAt)))
        send("cont", id: "continue-save")
        releaseGuest()
    }

    private func finishRestore() {
        report(String(format: "Quick start restored in %.2fs.\r\n", Date().timeIntervalSince(operationStartedAt)))
        send("cont", id: "continue-restore")
        releaseGuest()
    }

    private func fail(_ reason: String) {
        try? FileManager.default.removeItem(at: temporaryURL)
        if shouldRestore {
            try? FileManager.default.removeItem(at: snapshotURL)
            report("Quick start failed: \(reason). Relaunch NixTerm to rebuild it.\r\n")
        } else {
            report("Quick start unavailable: \(reason).\r\n")
            send("cont", id: "continue-failed-save")
            releaseGuest()
        }
    }

    private func send(_ command: String, arguments: [String: Any]? = nil, id: String) {
        guard descriptor >= 0 else { return }
        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments {
            message["arguments"] = arguments
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(contentsOf: [0x0D, 0x0A])
        write(data, to: descriptor)
    }

    private func write(_ data: Data, to socket: Int32) {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(socket, pointer, remaining)
                if count <= 0 {
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }
}
