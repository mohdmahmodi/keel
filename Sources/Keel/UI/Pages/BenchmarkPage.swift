import SwiftUI

struct BenchmarkPage: View {
    @Bindable var runner: BenchmarkRunner
    @State private var label = ""

    var subtitle: String {
        if runner.running {
            return runner.cancelling ? "Cancelling…" : "\(runner.currentTest) · \(Int((runner.progress * 100).rounded())) %"
        }
        return "Before/after measurements. Compare runs made on the same power source and energy mode."
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Benchmark", subtitle: subtitle) {
                if runner.running {
                    ProgressView(value: runner.progress).frame(width: 140)
                    Button("Cancel") { runner.cancel() }.disabled(runner.cancelling).keyboardShortcut(.cancelAction)
                } else {
                    TextField("Label (e.g. before tweaks)", text: $label).keelTextField().frame(width: 200)
                        .onSubmit(start)
                    Button("Run \(runner.selectedTests.count) tests", action: start)
                        .buttonStyle(.keelPrimary)
                        .disabled(runner.selectedTests.isEmpty)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BenchmarkConditionsCard(runner: runner)
                    BenchmarkTestPicker(runner: runner)
                    BenchmarkRunsList(runner: runner)
                    BenchmarkResultsTable(runner: runner)
                }
                .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 6)
            }
        }
    }

    func start() {
        guard !runner.running, !runner.selectedTests.isEmpty else { return }
        let l = label
        label = ""
        Task { await runner.run(label: l) }
    }
}
