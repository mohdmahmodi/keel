import Foundation

extension TweakCatalog {
    static let rosetta: [Tweak] = [
        Tweak(id: "rosetta-report", name: "Intel-only apps and Rosetta", category: .performance,
              summary: "Lists apps and running processes that still need Rosetta, Apple's Intel translator.",
              explanation: "Keel lists the apps on this Mac that are built only for Intel processors and the processes running through Rosetta right now. Rosetta translates Intel code for Apple silicon; translated code runs at roughly 50–98 % of native speed depending on the workload, and uses more energy for the same work. Apple has said macOS 27 is the last release with full Rosetta, and macOS 28 keeps it only for some older games. Keel finds Intel-only app bundles through Spotlight's executable-architecture metadata and translated processes through the kernel's P_TRANSLATED flag (0x20000 in `ps` flags), so you can replace or remove those apps in time. Keel never offers to uninstall Rosetta itself, because that requires turning off System Integrity Protection.",
              risk: .safe, impact: .medium, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  var vals: [(String, String)] = []
                  if let r = await Shell.probe("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemExecutableArchitectures == 'x86_64' && kMDItemExecutableArchitectures != 'arm64' && kMDItemExecutableArchitectures != 'arm64e'"], ttl: 60) {
                      for p in r.stdout.split(separator: "\n").prefix(15) { vals.append(((String(p) as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), "Intel only")) }
                  }
                  let intel = vals.count
                  var translated = 0
                  if let r = await Shell.probe("/bin/ps", ["-axo", "pid=,flags=,comm="]) {
                      for line in r.stdout.split(separator: "\n") {
                          let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
                          guard parts.count == 3, let flags = Int(parts[1], radix: 16), flags & 0x20000 != 0 else { continue }
                          translated += 1
                          vals.append(("running translated (pid \(parts[0]))", (String(parts[2]) as NSString).lastPathComponent))
                      }
                  }
                  let installed = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
                  vals.append(("Rosetta", installed ? "installed" : "not installed"))
                  if !installed && intel == 0 { return Detection(state: .on, values: vals, note: "Nothing on this Mac needs Rosetta.") }
                  let note = installed ? "\(intel) Intel-only app\(intel == 1 ? "" : "s"), \(translated) translated process\(translated == 1 ? "" : "es") right now."
                                       : "Rosetta is not installed, so the \(intel) Intel-only app\(intel == 1 ? "" : "s") listed cannot open."
                  return Detection(state: intel == 0 && translated == 0 ? .on : .partlyOn, values: vals, note: note)
              }, settingsURL: "", instructions: "Update, replace or remove the apps listed as Intel only.")),
              sources: ["https://support.apple.com/102527"],
              expectedBenefit: "Knowing which apps run slower and will stop working once Rosetta is gone.",
              tradeoff: "Nothing: this only reports.")
    ]
}
