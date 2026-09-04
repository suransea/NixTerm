import Darwin
import Foundation

final class QEMUTerminalBackend {
    static let shared = QEMUTerminalBackend()

    private let queue = DispatchQueue(label: "dev.nixterm.qemu.serial", qos: .userInteractive)
    private let readQueue = DispatchQueue(label: "dev.nixterm.qemu.serial.read", qos: .userInteractive)
    private let runner = NixTermQEMURunner()
    private var socketDescriptor: Int32 = -1
    private var output: ((Data) -> Void)?
    private var quickStart: QuickStartController?
    private var acceptingInput = false
    private var serialProbe = Data()
    private var startedAt = Date()
    private var reportedReady = false
    private var releaseInputOnConnect = false
    private var autoLoginFreeBSD = false
    private var sentFreeBSDLogin = false
    private var started = false

    private let snapshotMarker = Data("\u{1B}]777;nixterm-snapshot-ready\u{07}".utf8)
    private let readyMarker = Data("\u{1B}]777;nixterm-ready\u{07}".utf8)
    private let loginPrompt = Data("login:".utf8)

    func start(output: @escaping (Data) -> Void) {
        self.output = output
        guard !started else {
            resume()
            return
        }
        started = true

        if let disk = Bundle.main.url(forResource: "FreeBSD", withExtension: "qcow2"),
           let overlay = Bundle.main.url(forResource: "FreeBSD-overlay", withExtension: "qcow2"),
           let firmware = Bundle.main.url(forResource: "QEMU_EFI", withExtension: "fd")
        {
            startFreeBSD(baseDisk: disk, overlayTemplate: overlay, firmware: firmware)
            return
        }

        guard
            let kernel = Bundle.main.url(forResource: "Image", withExtension: nil),
            let rootFileSystem = Bundle.main.url(forResource: "root", withExtension: "squashfs")
        else {
            report("Nix-built Linux guest resources are missing.\r\n")
            return
        }

        let serialPort: UInt16 = 37733
        let monitorPort: UInt16 = 37734
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            report("Unable to locate the persistent Documents directory.\r\n")
            return
        }
        let readme = documents.appendingPathComponent("README.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let contents = "NixTerm home directory\n\nFiles stored here are available as /root in the Linux guest.\n"
            try? contents.write(to: readme, atomically: true, encoding: .utf8)
        }
        quickStart = QuickStartController(
            report: { [weak self] message in self?.report(message) },
            releaseGuest: { [weak self] in self?.releaseGuestBarrier() }
        )

        var arguments = [
            "-machine", "virt",
            "-cpu", "cortex-a53",
            "-accel", "tcg,thread=single,tb-size=64",
            "-rtc", "base=utc,clock=host",
            "-smp", "1",
            "-m", "256",
            "-nodefaults",
            "-nographic",
            "-no-reboot",
            "-audio", "none",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-drive", "file=\(rootFileSystem.path),format=raw,if=none,id=rootfs,readonly=on",
            "-device", "virtio-blk-pci,drive=rootfs,romfile=",
            "-virtfs", "local,path=\(documents.path),mount_tag=hostshare,security_model=none,id=hostshare",
            "-chardev", "socket,id=serial0,host=127.0.0.1,port=\(serialPort),server=on,wait=off",
            "-serial", "chardev:serial0",
            "-qmp", "tcp:127.0.0.1:\(monitorPort),server=on,wait=off",
            "-kernel", kernel.path,
            "-append", "console=ttyAMA0,115200 root=/dev/vda rootfstype=squashfs ro init=/init panic=-1 loglevel=4 nowatchdog",
        ]
        if quickStart?.shouldRestore == true {
            arguments += ["-incoming", "defer"]
        }

        startedAt = Date()
        report(quickStart?.shouldRestore == true ? "Restoring quick start...\r\n" : "Preparing Linux...\r\n")
        runner.start(withArguments: arguments) { [weak self] error in
            guard let self else { return }
            if let error {
                report("QEMU failed: \(error.localizedDescription)\r\n")
                return
            }
            queue.async {
                self.connect(to: serialPort)
            }
            quickStart?.connect(to: monitorPort)
        }
    }

    private func startFreeBSD(baseDisk: URL, overlayTemplate: URL, firmware: URL) {
        report("Preparing FreeBSD...\r\n")
        queue.async { [weak self] in
            guard let self,
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let digest = QuickStartController.signedResourceDigest(named: "FreeBSD.qcow2")
            else {
                self?.report("Unable to prepare the FreeBSD disk.\r\n")
                return
            }

            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let storage = support.appendingPathComponent("freebsd-\(digest)", isDirectory: true)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                let storedBase = storage.appendingPathComponent("FreeBSD.qcow2")
                let initialOverlay = storage.appendingPathComponent("FreeBSD-overlay.qcow2")
                let currentLayerFile = storage.appendingPathComponent("current-layer")
                if !FileManager.default.fileExists(atPath: storedBase.path) {
                    try FileManager.default.copyItem(at: baseDisk, to: storedBase)
                }
                if !FileManager.default.fileExists(atPath: initialOverlay.path) {
                    try FileManager.default.copyItem(at: overlayTemplate, to: initialOverlay)
                }
                let currentName = (try? String(contentsOf: currentLayerFile, encoding: .utf8)) ?? initialOverlay.lastPathComponent
                let disk = storage.appendingPathComponent(currentName)
                guard FileManager.default.fileExists(atPath: disk.path) else {
                    report("Unable to locate the active FreeBSD disk layer.\r\n")
                    return
                }
                let nextDisk = storage.appendingPathComponent("layer-\(UUID().uuidString).qcow2")

                autoLoginFreeBSD = true
                quickStart = QuickStartController(
                    report: { [weak self] message in self?.report(message) },
                    releaseGuest: { [weak self] in self?.releaseGuestBarrier() },
                    resources: ["FreeBSD.qcow2", "FreeBSD-overlay.qcow2", "QEMU_EFI.fd"],
                    namePrefix: "nixterm-freebsd-quickstart-v1",
                    activeDiskURL: disk,
                    nextDiskURL: nextDisk,
                    minimumStableDiskSize: 1_048_576,
                    diskDidPivot: { url in
                        try? url.lastPathComponent.write(to: currentLayerFile, atomically: true, encoding: .utf8)
                    }
                )
                startedAt = Date()
                let serialPort: UInt16 = 37733
                let monitorPort: UInt16 = 37734
                var arguments = [
                    "-machine", "virt,gic-version=3",
                    "-cpu", "cortex-a53",
                    "-accel", "tcg,thread=single,tb-size=64",
                    "-rtc", "base=utc,clock=host",
                    "-smp", "1",
                    "-m", "512",
                    "-nodefaults",
                    "-nographic",
                    "-no-reboot",
                    "-audio", "none",
                    "-netdev", "user,id=net0",
                    "-device", "virtio-net-pci,netdev=net0,romfile=",
                    "-device", "virtio-rng-pci,romfile=",
                    "-drive", "file=\(disk.path),format=qcow2,if=none,id=rootfs",
                    "-device", "virtio-blk-pci,drive=rootfs,bootindex=1,romfile=",
                    "-virtfs", "local,path=\(documents.path),mount_tag=hostshare,security_model=none,id=hostshare",
                    "-bios", firmware.path,
                    "-chardev", "socket,id=serial0,host=127.0.0.1,port=\(serialPort),server=on,wait=off",
                    "-serial", "chardev:serial0",
                    "-qmp", "tcp:127.0.0.1:\(monitorPort),server=on,wait=off",
                ]
                if quickStart?.shouldRestore == true {
                    arguments += ["-incoming", "defer"]
                }
                report(quickStart?.shouldRestore == true ? "Restoring quick start...\r\n" : "Booting FreeBSD...\r\n")
                runner.start(withArguments: arguments) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        report("QEMU failed: \(error.localizedDescription)\r\n")
                        return
                    }
                    queue.async {
                        self.connect(to: serialPort)
                    }
                    quickStart?.connect(to: monitorPort)
                }
            } catch {
                report("Unable to prepare the FreeBSD disk: \(error.localizedDescription)\r\n")
            }
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, acceptingInput else { return }
            write(data)
        }
    }

    func resume() {
        quickStart?.resume()
        queue.async { [weak self] in
            guard let self, socketDescriptor < 0 else { return }
            connect(to: 37733)
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }

        let sizeFile = documents.appendingPathComponent(".nixterm-size")
        try? "\(columns) \(rows)\n".write(to: sizeFile, atomically: true, encoding: .utf8)
    }

    func stop() {
        quickStart?.stop()
        queue.async { [weak self] in
            guard let self, socketDescriptor >= 0 else { return }
            Darwin.close(socketDescriptor)
            socketDescriptor = -1
        }
    }

    private func connect(to port: UInt16) {
        for _ in 0 ..< 300 {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                report("Unable to create the serial socket.\r\n")
                return
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            let converted = "127.0.0.1".withCString {
                inet_pton(AF_INET, $0, &address.sin_addr)
            }
            guard converted == 1 else {
                Darwin.close(descriptor)
                report("Unable to configure the serial socket.\r\n")
                return
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                socketDescriptor = descriptor
                if releaseInputOnConnect {
                    acceptingInput = true
                }
                readQueue.async { [weak self] in
                    self?.readOutput(from: descriptor)
                }
                return
            }
            Darwin.close(descriptor)
            usleep(100_000)
        }
        report("Timed out connecting to the Linux serial console.\r\n")
    }

    private func readOutput(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            let data = Data(buffer[0 ..< count])
            output?(data)
            serialProbe.append(data)
            if serialProbe.count > 512 {
                serialProbe.removeFirst(serialProbe.count - 512)
            }
            if serialProbe.range(of: snapshotMarker) != nil {
                if let quickStart {
                    quickStart.guestReachedBarrier()
                } else {
                    releaseGuestBarrier()
                }
            }
            if autoLoginFreeBSD, !sentFreeBSDLogin, serialProbe.range(of: loginPrompt) != nil {
                sentFreeBSDLogin = true
                queue.async { [weak self] in
                    self?.write(Data("root\r".utf8))
                }
            }
            if !reportedReady, serialProbe.range(of: readyMarker) != nil {
                reportedReady = true
                report(String(format: "\r\nReady in %.2fs.\r\n", Date().timeIntervalSince(startedAt)))
            }
        }
        queue.async { [weak self] in
            guard let self, socketDescriptor == descriptor else { return }
            Darwin.close(descriptor)
            socketDescriptor = -1
        }
    }

    private func report(_ message: String) {
        output?(Data(message.utf8))
    }

    private func releaseGuestBarrier() {
        queue.async { [weak self] in
            guard let self else { return }
            write(Data("\n".utf8))
            acceptingInput = true
        }
    }

    private func write(_ data: Data) {
        guard socketDescriptor >= 0 else { return }
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(socketDescriptor, pointer, remaining)
                if count <= 0 {
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }
}
