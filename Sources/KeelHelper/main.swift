import Foundation
import Security
import KeelShared

// --xpc: launchd daemon registered with SMAppService. run <base64>: one-shot via the administrator prompt.

let args = CommandLine.arguments

func emit(_ results: [OpResult]) {
    let data = (try? JSONEncoder().encode(results)) ?? Data("[]".utf8)
    FileHandle.standardOutput.write(data)
}

if args.contains("--version") { print(KeelConstants.helperVersion); exit(0) }

if args.count >= 3 && args[1] == "run" {
    guard geteuid() == 0 else { emit([OpResult(ok: false, output: "helper must run as root")]); exit(1) }
    guard let data = Data(base64Encoded: args[2]), let req = try? JSONDecoder().decode(PrivRequest.self, from: data) else {
        emit([OpResult(ok: false, output: "bad request")]); exit(1)
    }
    emit(PrivExecutor.perform(req))
    exit(0)
}

if args.contains("--xpc") {
    /// launchd starts the helper on demand; it exits after 60 s idle.
    final class Idle: @unchecked Sendable {
        static let shared = Idle()
        private let lock = NSLock(); private var last = Date(); private var active = 0
        func begin() { lock.lock(); active += 1; last = Date(); lock.unlock() }
        func end() { lock.lock(); active -= 1; last = Date(); lock.unlock() }
        var expired: Bool { lock.lock(); defer { lock.unlock() }; return active == 0 && Date().timeIntervalSince(last) > 60 }
    }
    let idleTimer = DispatchSource.makeTimerSource(queue: .global())
    idleTimer.schedule(deadline: .now() + 30, repeating: 15)
    idleTimer.setEventHandler { if Idle.shared.expired { exit(0) } }
    idleTimer.resume()

    final class Service: NSObject, KeelHelperXPC {
        let uid: uid_t
        init(uid: uid_t) { self.uid = uid }
        func run(_ request: Data, reply: @escaping (Data) -> Void) {
            Idle.shared.begin(); defer { Idle.shared.end() }
            guard var req = try? JSONDecoder().decode(PrivRequest.self, from: request) else {
                reply((try? JSONEncoder().encode([OpResult(ok: false, output: "bad request")])) ?? Data()); return
            }
            // Never trust the payload's uid; use the connection's.
            req = PrivRequest(ops: req.ops, uid: uid)
            reply((try? JSONEncoder().encode(PrivExecutor.perform(req))) ?? Data())
        }
        func version(reply: @escaping (String) -> Void) { reply(KeelConstants.helperVersion) }
    }

    final class Delegate: NSObject, NSXPCListenerDelegate {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            c.exportedInterface = NSXPCInterface(with: KeelHelperXPC.self)
            c.exportedObject = Service(uid: c.effectiveUserIdentifier)
            c.resume()
            return true
        }
    }

    /// Only clients signed by the same team as this helper, with Keel's bundle identifier, may connect.
    func clientRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return "anchor apple generic and identifier \"\(KeelConstants.appBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    guard let requirement = clientRequirement() else {
        FileHandle.standardError.write("KeelHelper: not signed with a team identity; refusing to serve XPC\n".data(using: .utf8)!)
        exit(1)
    }
    let delegate = Delegate()
    let listener = NSXPCListener(machServiceName: KeelConstants.helperMachService)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()
    RunLoop.main.run()
}

FileHandle.standardError.write("usage: KeelHelper --xpc | run <base64-request> | --version\n".data(using: .utf8)!)
exit(64)
