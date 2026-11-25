import Darwin
import Foundation

private func run() {
    guard let caller = CompanionBridgeCaller.nativeMessaging(CommandLine.arguments) else { return }
    signal(SIGPIPE, SIG_IGN)
    do {
        try CompanionBridgeWire.nonblocking(STDIN_FILENO)
        try CompanionBridgeWire.nonblocking(STDOUT_FILENO)
        let bytes = try CompanionBridgeWire.readFrame(from: STDIN_FILENO, until: .now() + .seconds(10))
        let request: CompanionBridgeRequest
        do {
            request = try CompanionBridgeRequest(json: CompanionBridgeWire.object(bytes))
        } catch {
            write(CompanionBridgeFailure.invalid.response)
            return
        }
        let client = CompanionBrokerClient(disconnectDescriptor: STDIN_FILENO)
        do {
            let descriptor = try client.open(request, as: caller)
            defer { Darwin.close(descriptor) }
            var deadline: DispatchTime?
            repeat {
                let reply = try client.readReply(for: request, from: descriptor, deadline: deadline)
                try CompanionBridgeWire.writeFrame(reply, to: STDOUT_FILENO, until: .now() + .seconds(2),
                                                   disconnect: STDIN_FILENO)
                guard request.operation == .watchStatus,
                      (try CompanionBridgeWire.object(reply))["type"] as? String == "status" else { return }
                // Once the next status frame is readable, bound assembly. A
                // dormant subscription waits without requiring heartbeats.
                try CompanionBridgeWire.wait(descriptor, events: Int16(POLLIN), until: nil, disconnect: STDIN_FILENO)
                deadline = .now() + .seconds(3)
            } while true
        } catch CompanionBridgeFailure.disconnected {
            return
        } catch {
            if request.operation != .watchStatus {
                write(((error as? CompanionBridgeFailure) ?? .unavailable).response)
            }
        }
    } catch CompanionBridgeFailure.invalid {
        write(CompanionBridgeFailure.invalid.response)
    } catch {
        // stdout is exclusively for browser responses. Connection or framing
        // failures never log requests, payloads, or results.
    }
}

private func write(_ response: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: response) else { return }
    try? CompanionBridgeWire.writeFrame(bytes, to: STDOUT_FILENO, until: .now() + .seconds(2), disconnect: STDIN_FILENO)
}

run()
