import AgoraCore
import SwiftUI

/// A Bot's Routines next to its chat: schedule, next run, last result, and controls.
struct RoutinesPanel: View {
    @Environment(AgoraCore.self) private var core
    let bot: Bot
    @State private var confirmDelete: Routine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ROUTINES").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                Button {
                    Task { await core.loadRoutines(for: bot.name) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !core.features.routines {
                        Text("This Hermes doesn't let Agora manage Routines.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if (core.routines[bot.name] ?? []).isEmpty {
                        Text("\(bot.title) has no Routines yet.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    ForEach(core.routines[bot.name] ?? []) { routine in
                        RoutineRow(routine: routine) { confirmDelete = routine }
                    }
                    Text("To add one, ask \(bot.title) in chat, for example “brief me on the markets every weekday at 7am”.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.sidebarBackground.opacity(0.5))
        .task(id: bot.name) { await core.loadRoutines(for: bot.name) }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Routine", role: .destructive) {
                if let r = confirmDelete { Task { await core.delete(r) } }
            }
        } message: {
            Text("\(bot.title) will stop running it.")
        }
    }
}

struct RoutineRow: View {
    @Environment(AgoraCore.self) private var core
    let routine: Routine
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(routine.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer()
                if routine.running { ProgressView().controlSize(.mini) } else if routine.paused {
                    Text("Paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            Text(routine.schedule).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let next = routine.nextRun, !routine.paused {
                Text("Next: \(next.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let status = routine.lastStatus {
                HStack(spacing: 4) {
                    Image(systemName: status == "ok" ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(status == "ok" ? .green : .orange)
                    Text(lastText(status)).lineLimit(2)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if routine.paused {
                    Button("Resume") { Task { await core.resume(routine) } }
                } else {
                    Button("Pause") { Task { await core.pause(routine) } }
                }
                Button("Run now") { Task { await core.runNow(routine) } }.disabled(routine.running)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    func lastText(_ status: String) -> String {
        let when = routine.lastRun.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""
        if status == "ok" { return "Last run OK\(when)" }
        return "Last run: \(routine.lastError ?? status)\(when)"
    }
}
