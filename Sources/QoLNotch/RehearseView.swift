import SwiftUI

private func clock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

/// Shows how the last run-through went, and how runs compare over time.
struct RehearseView: View {
    @ObservedObject var model: PrompterModel

    var body: some View {
        Form {
            Section("Team") {
                if model.speakers.isEmpty {
                    Text("Start a line with a name, like **@Itim:**, to mark who says what. Each person then picks their name here and gets a cue before their turn.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("I am", selection: $model.mySpeaker) {
                        Text("Everyone (no cue)").tag("")
                        ForEach(model.speakers, id: \.self) { Text($0).tag($0) }
                    }
                    .help("Pick your name to dim everyone else's lines and get a cue just before your turn.")
                }
            }

            Section("Target") {
                LabeledContent("Time limit") {
                    HStack {
                        Slider(value: $model.targetMinutes, in: 0...30, step: 0.5).frame(maxWidth: 220)
                        Text(model.targetMinutes > 0 ? clock(model.targetMinutes * 60) : "None")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .help("How long your talk is allowed to run. After each run QoL Notch tells you how far over or under you were.")
            }

            if let report = model.report {
                Section("Last run") {
                    HStack(spacing: 0) {
                        stat(clock(report.duration), "time", tint: timeTint(report))
                        stat("\(Int(report.wordsPerMinute.rounded()))", "words / min")
                        stat("\(report.pauses.count)", "long pauses")
                        stat("\(report.fillerCount)", "filler words")
                    }
                    if !report.finished {
                        Text("Stopped at word \(report.wordsSpoken) of \(report.totalWords).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let verdict = targetVerdict(report) {
                        Text(verdict).font(.callout)
                    }
                }

                if !report.sections.isEmpty {
                    Section("Time per section") {
                        ForEach(report.sections) { section in
                            Button { model.jump(to: section.firstWord) } label: {
                                HStack {
                                    Text(section.title).lineLimit(1)
                                    Spacer()
                                    Text("\(section.words) words").foregroundStyle(.secondary)
                                    Text(clock(section.seconds)).monospacedDigit().frame(width: 44, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !report.pauses.isEmpty {
                    Section("Where you paused") {
                        ForEach(report.pauses) { pause in
                            Button { model.jump(to: pause.wordIndex) } label: {
                                HStack {
                                    Text("…\(pause.context)…").lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.1f s", pause.seconds)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Jump to this spot")
                        }
                    }
                }

                if !report.fillers.isEmpty {
                    Section("Filler words (approximate)") {
                        Text(report.fillers.map { "\($0.word) ×\($0.count)" }.joined(separator: "   "))
                    }
                }
            } else {
                Section("Last run") {
                    Text("Press Start and read your script. When you pause or finish, your time, pace and pauses show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if model.history.count > 1 {
                Section("Earlier runs") {
                    ForEach(model.history.dropFirst().prefix(8)) { run in
                        HStack {
                            Text(run.date, format: .dateTime.day().month().hour().minute())
                            Spacer()
                            Text("\(Int(run.wordsPerMinute.rounded())) wpm").foregroundStyle(.secondary)
                            Text("\(run.pauses.count) pauses").foregroundStyle(.secondary)
                            Text(clock(run.duration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Button("Clear History", role: .destructive) { model.clearHistory() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeTint(_ report: RehearsalReport) -> Color {
        guard model.targetMinutes > 0, report.finished else { return .primary }
        return report.duration > model.targetMinutes * 60 ? .red : .green
    }

    /// Compares the run, or its projected full length, with the time limit.
    private func targetVerdict(_ report: RehearsalReport) -> String? {
        guard model.targetMinutes > 0, report.wordsSpoken > 0 else { return nil }
        let target = model.targetMinutes * 60
        let projected = report.finished
            ? report.duration
            : report.duration / Double(report.wordsSpoken) * Double(report.totalWords)
        let difference = projected - target
        let label = report.finished ? "You finished" : "At this pace the full script takes \(clock(projected)),"
        if abs(difference) < 5 { return "\(label) right on your \(clock(target)) limit." }
        return difference > 0
            ? "\(label) \(clock(difference)) over your \(clock(target)) limit."
            : "\(label) \(clock(-difference)) under your \(clock(target)) limit."
    }
}

/// Controls for the phone remote.
struct RemoteView: View {
    @ObservedObject var remote = RemoteController.shared

    var body: some View {
        Form {
            Section("Phone remote") {
                Toggle("Let a phone on this Wi-Fi control the prompter", isOn: $remote.enabled)
                    .help("Shows a QR code. Scan it to start, pause and step through the script from your phone's browser.")
                if let error = remote.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if remote.enabled, let image = remote.qrCode, let url = remote.url {
                    HStack(alignment: .top, spacing: 18) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with your phone's camera.")
                            Text("No app to install. The phone must be on the same Wi-Fi as this Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(url).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                            Text("The link holds a private code. Anyone with it can control the prompter until you turn this off.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if !remote.enabled {
                    Text("Start, pause, step and resize text from your phone's browser.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
