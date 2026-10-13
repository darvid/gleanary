import SwiftUI

struct CaptureQueueView: View {
    let library: LibraryModel
    @State private var expanded = true

    var body: some View {
        if !library.captureJobs.isEmpty {
            DisclosureGroup("Captures", isExpanded: $expanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(library.captureJobs) { job in
                            HStack(alignment: .top, spacing: 10) {
                                if job.state == .fetching || job.state == .extracting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: symbol(job.state)).foregroundStyle(.secondary)
                                        .accessibilityLabel(job.state.rawValue)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(job.request.label).lineLimit(1).help(job.request.label)
                                    Text(job
                                        .error ??
                                        (job.progress.isEmpty ? job.state.rawValue.capitalized : job
                                            .progress))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if !job.state.terminal {
                                    Button("Cancel") { Task { await library.cancelCapture(job.id) }
                                    }
                                } else if job.state == .failed || job.state == .cancelled {
                                    if job.state == .failed, job.recovery == .browser {
                                        Button("Open browser") { library.browserJob = job }
                                    } else if job.state == .failed, job.recovery == .audio {
                                        Button("Audio options") { library.audioJob = job }
                                    }
                                    Button("Retry") { Task { await library.retryCapture(job.id) } }
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }.padding(.top, 8).padding(.trailing, 4)
                }.frame(maxHeight: 130)
            }
            .onChange(of: library.captureJobs.count) { expanded = true }
            .onChange(of: library.hasSearched) {
                if library.hasSearched {
                    expanded = false
                }
            }
        }
    }

    private func symbol(_ state: CaptureState) -> String {
        switch state {
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        default: "clock"
        }
    }
}
