import SwiftUI

/// Test selection, live per-test status during a run, and what each test measures.
struct BenchmarkTestPicker: View {
    @Bindable var runner: BenchmarkRunner
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionTitle(text: "Tests")
                ChipButton(text: "All", selected: false) { runner.selectedTests = Set(BenchmarkTest.allCases) }.disabled(runner.running)
                ChipButton(text: "Local only", selected: false) {
                    runner.selectedTests = Set(BenchmarkTest.allCases.filter { $0.group != "Network" && $0.group != "AI" })
                }.disabled(runner.running)
                ChipButton(text: "None", selected: false) { runner.selectedTests = [] }.disabled(runner.running)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(BenchmarkTest.groups, id: \.self) { g in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(g).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(BenchmarkTest.allCases.filter { $0.group == g }) { t in row(t) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .card(padding: 10)
                }
            }
            Text("A full run takes about a minute, plus Ollama. SSD tests write about 6 GiB to a temporary file and delete it; network responsiveness transfers a few hundred MB.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showInfo) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(BenchmarkTest.allCases) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                            Text(t.explanation).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                            Text("Affected by: " + t.affectedBy).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 12)
                .padding(.top, 6)
            } label: {
                Text("What each test measures").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func row(_ t: BenchmarkTest) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { runner.selectedTests.contains(t) },
                                 set: { if $0 { runner.selectedTests.insert(t) } else { runner.selectedTests.remove(t) } })) {
                Text(t.shortName).font(.system(size: 11.5))
            }
            .toggleStyle(KeelCheckboxStyle())
            .disabled(runner.running)
            Spacer(minLength: 6)
            statusView(runner.status[t])
        }
        .frame(height: 18)
        .help(t.explanation + "\n\nAffected by: " + t.affectedBy)
    }

    @ViewBuilder
    func statusView(_ s: TestStatus?) -> some View {
        switch s {
        case .none: EmptyView()
        case .pending?: Image(systemName: "circle.dotted").font(.system(size: 10)).foregroundStyle(.tertiary)
        case .running?: ProgressView().controlSize(.mini)
        case .done(let v)?: Text(v).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
        case .skipped(let why)?: Chip(text: "SKIPPED").help(why)
        case .failed(let why)?: Chip(text: "FAILED", color: Theme.fail).help(why)
        case .cancelled?: Chip(text: "CANCELLED")
        }
    }
}
