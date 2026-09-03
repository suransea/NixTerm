import Darwin
import Foundation

final class QEMUTerminalBackend {
    private let queue = DispatchQueue(label: "dev.nixterm.qemu.serial", qos: .userInteractive)
    private let runner = NixTermQEMURunner()
    private var socketDescriptor: Int32 = -1
    private var output: ((Data) -> Void)?

    func start(output: @escaping (Data) -> Void) {
        self.output = output

        guard
            let kernel = Bundle.main.url(forResource: "Image", withExtension: nil),
            let initramfs = Bundle.main.url(forResource: "initramfs.cpio", withExtension: "gz")
        else {
            report("Nix-built Linux guest resources are missing.\r\n")
            return
        }

        let serialPort: UInt16 = 37_733
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            report("Unable to locate the persistent Documents directory.\r\n")
            return
        }
        let arguments = [
            "-machine", "virt",
            "-cpu", "cortex-a53",
            "-accel", "tcg,tb-size=64",
            "-smp", "1",
            "-m", "1024",
            "-nodefaults",
            "-nographic",
            "-no-reboot",
            "-audio", "none",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-virtfs", "local,path=\(documents.path),mount_tag=hostshare,security_model=none,id=hostshare",
            "-chardev", "socket,id=serial0,host=127.0.0.1,port=\(serialPort),server=on,wait=off",
            "-serial", "chardev:serial0",
            "-kernel", kernel.path,
            "-initrd", initramfs.path,
            "-append", "console=ttyAMA0,115200 rdinit=/init panic=-1 loglevel=4",
        ]

        report("Booting Nix-built aarch64 Linux with interpreted QEMU...\r\n")
        runner.start(withArguments: arguments) { [weak self] error in
            guard let self else { return }
            if let error {
                report("QEMU failed: \(error.localizedDescription)\r\n")
                return
            }
            queue.async {
                self.connect(to: serialPort)
            }
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, socketDescriptor >= 0 else { return }
            data.withUnsafeBytes { bytes in
                guard var pointer = bytes.baseAddress else { return }
                var remaining = bytes.count
                while remaining > 0 {
                    let count = Darwin.write(self.socketDescriptor, pointer, remaining)
                    if count <= 0 {
                        return
                    }
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                }
            }
        }
    }

    func resize(columns _: Int, rows _: Int) {}

    func stop() {
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
                readOutput()
                return
            }
            Darwin.close(descriptor)
            usleep(100_000)
        }
        report("Timed out connecting to the Linux serial console.\r\n")
    }

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while socketDescriptor >= 0 {
            let count = Darwin.read(socketDescriptor, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            output?(Data(buffer[0 ..< count]))
        }
    }

    private func report(_ message: String) {
        output?(Data(message.utf8))
    }
}
