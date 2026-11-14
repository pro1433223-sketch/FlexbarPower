import Foundation

@objc protocol FlexbarPowerProtocol {
    func status(reply: @escaping (String, Int32) -> Void)
    func setPower(_ enabled: Bool, reply: @escaping (String, Int32) -> Void)
    func cycle(reply: @escaping (String, Int32) -> Void)
}

final class PowerService: NSObject, FlexbarPowerProtocol {
    private let queue = DispatchQueue(label: "local.flexbar.power.commands", qos: .userInitiated)

    func status(reply: @escaping (String, Int32) -> Void) {
        run(["-l", "2-1", "-p", "2"], reply: reply)
    }

    func setPower(_ enabled: Bool, reply: @escaping (String, Int32) -> Void) {
        run(["-l", "2-1", "-p", "2", "-a", enabled ? "on" : "off"], reply: reply)
    }

    func cycle(reply: @escaping (String, Int32) -> Void) {
        run(["-l", "2-1", "-p", "2", "-a", "cycle", "-d", "3"], reply: reply)
    }

    private func run(_ arguments: [String], reply: @escaping (String, Int32) -> Void) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/uhubctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                var outputData = Data()
                let readFinished = DispatchGroup()
                readFinished.enter()
                DispatchQueue.global(qos: .utility).async {
                    outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    readFinished.leave()
                }
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    process.terminate()
                    _ = readFinished.wait(timeout: .now() + 2)
                    reply("uhubctl 执行超时（15 秒），已停止。", 124)
                    return
                }
                _ = readFinished.wait(timeout: .now() + 2)
                let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                reply(output, process.terminationStatus)
            } catch {
                reply(error.localizedDescription, 1)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = PowerService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FlexbarPowerProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "local.flexbar.power.helper")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
