import Foundation

/// Runs validated ops as root inside the helper. Never uses a shell.
public enum PrivExecutor {
    static func run(_ exe: String, _ args: [String]) -> OpResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return OpResult(ok: false, output: "launch failed: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return OpResult(ok: p.terminationStatus == 0, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func sysctlDaemonPlist(label: String, name: String, value: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>/usr/sbin/sysctl</string><string>-w</string><string>\(name)=\(value)</string></array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
    }

    public static func perform(_ request: PrivRequest) -> [OpResult] {
        guard let pw = getpwuid(request.uid), let dir = pw.pointee.pw_dir else { return [OpResult(ok: false, output: "unknown user")] }
        let home = String(cString: dir)
        var memMB = 0
        var size = MemoryLayout<UInt64>.size
        var mem: UInt64 = 0
        if sysctlbyname("hw.memsize", &mem, &size, nil, 0) == 0 { memMB = Int(mem / 1_048_576) }
        var results: [OpResult] = []
        for op in request.ops {
            do { try op.validate(home: home, memoryMB: memMB) } catch {
                results.append(OpResult(ok: false, output: "\(error)")); continue
            }
            results.append(execute(op, uid: request.uid))
        }
        return results
    }

    static func execute(_ op: PrivOp, uid: UInt32) -> OpResult {
        let fm = FileManager.default
        switch op {
        case .pmset(let s, let k, let v): return run("/usr/bin/pmset", [s, k, v])
        case .pmsetRepeatCancel: return run("/usr/bin/pmset", ["repeat", "cancel"])
        case .pmsetRepeat(let t, let d, let h): return run("/usr/bin/pmset", ["repeat", t, d, h])
        case .sysctl(let n, let v): return run("/usr/sbin/sysctl", ["-w", "\(n)=\(v)"])
        case .installSysctlDaemon(let n, let v):
            let label = KeelConstants.sysctlDaemonLabel(n)
            let path = "/Library/LaunchDaemons/\(label).plist"
            _ = run("/bin/launchctl", ["bootout", "system/\(label)"])
            do {
                try sysctlDaemonPlist(label: label, name: n, value: v).write(toFile: path, atomically: true, encoding: .utf8)
                try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: path)
            } catch { return OpResult(ok: false, output: "write \(path): \(error.localizedDescription)") }
            return run("/bin/launchctl", ["bootstrap", "system", path])
        case .removeSysctlDaemon(let n):
            let label = KeelConstants.sysctlDaemonLabel(n)
            _ = run("/bin/launchctl", ["bootout", "system/\(label)"])
            try? fm.removeItem(atPath: "/Library/LaunchDaemons/\(label).plist")
            return OpResult(ok: true, output: "removed \(label)")
        case .launchctl(let verb, let dom, let t):
            let r = verb == "bootstrap" ? run("/bin/launchctl", ["bootstrap", dom, t]) : run("/bin/launchctl", [verb, "\(dom)/\(t)"])
            // bootout of a service that isn't loaded counts as success.
            if verb == "bootout" && !r.ok && (r.output.contains("No such process") || r.output.contains("Could not find")) { return OpResult(ok: true, output: r.output) }
            return r
        case .moveFile(let f, let t):
            do {
                if fm.fileExists(atPath: t) { try fm.removeItem(atPath: t) }
                try fm.moveItem(atPath: f, toPath: t)
                if t.hasPrefix("/Library/") { try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: t) }
                else { try fm.setAttributes([.ownerAccountID: uid], ofItemAtPath: t) }
                return OpResult(ok: true, output: "moved")
            } catch { return OpResult(ok: false, output: error.localizedDescription) }
        case .copyFile(let f, let t):
            do {
                if fm.fileExists(atPath: t) { try fm.removeItem(atPath: t) }
                try fm.copyItem(atPath: f, toPath: t)
                if t.hasPrefix("/Library/") { try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: t) }
                else { try fm.setAttributes([.ownerAccountID: uid], ofItemAtPath: t) }
                return OpResult(ok: true, output: "copied")
            } catch { return OpResult(ok: false, output: error.localizedDescription) }
        case .removeFile(let p):
            do { try fm.removeItem(atPath: p); return OpResult(ok: true, output: "removed") }
            catch { return OpResult(ok: !fm.fileExists(atPath: p), output: error.localizedDescription) }
        case .setDNS(let s, let ips): return run("/usr/sbin/networksetup", ["-setdnsservers", s] + ips)
        case .flushDNS:
            _ = run("/usr/bin/dscacheutil", ["-flushcache"])
            return run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        case .firewall(let g, let s):
            let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
            var out = OpResult(ok: true, output: "")
            if let g { out = run(fw, ["--setglobalstate", g ? "on" : "off"]); if !out.ok { return out } }
            if let s { out = run(fw, ["--setstealthmode", s ? "on" : "off"]) }
            return out
        case .tmExclusion(let p, let add): return run("/usr/bin/tmutil", [add ? "addexclusion" : "removeexclusion", "-p", p])
        case .crashReporter(let a, let t):
            let plist = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
            var r = OpResult(ok: true, output: "")
            if let a { r = run("/usr/bin/defaults", ["write", plist, "AutoSubmit", "-bool", a ? "true" : "false"]); if !r.ok { return r } }
            if let t { r = run("/usr/bin/defaults", ["write", plist, "ThirdPartyDataSubmit", "-bool", t ? "true" : "false"]) }
            _ = run("/bin/chmod", ["644", plist])
            return r
        case .interface(let n, let up): return run("/sbin/ifconfig", [n, up ? "up" : "down"])
        case .powermetrics(let s, let ms): return run("/usr/bin/powermetrics", ["--samplers", s, "-i", String(ms), "-n", "1"])
        case .mdutil(let v, let on): return run("/usr/bin/mdutil", ["-i", on ? "on" : "off", v])
        case .networkServiceEnabled(let s, let on): return run("/usr/sbin/networksetup", ["-setnetworkserviceenabled", s, on ? "on" : "off"])
        case .rootDefaults(let d, let k, let v):
            if let v { return run("/usr/bin/defaults", ["write", d, k, "-bool", v ? "true" : "false"]) }
            let r = run("/usr/bin/defaults", ["delete", d, k])
            return r.ok || r.output.contains("does not exist") ? OpResult(ok: true, output: r.output) : r
        case .systemsetup(let f, let on): return run("/usr/sbin/systemsetup", [f, on ? "on" : "off"])
        case .nvram(let n, let v):
            if let v { return run("/usr/sbin/nvram", ["\(n)=\(v)"]) }
            let r = run("/usr/sbin/nvram", ["-d", n])
            return r.ok || r.output.contains("not found") ? OpResult(ok: true, output: r.output) : r
        }
    }
}
