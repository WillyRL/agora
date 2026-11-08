import AgoraCore
import SwiftUI

/// A card for something the Bot is waiting on: an approval, a question, or a secret.
struct PromptCard: View {
    @Environment(AgoraCore.self) private var core
    let prompt: PendingPrompt
    let bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 22)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.35)))
        .shadow(color: Theme.accent.opacity(0.08), radius: 8, y: 2)
    }

    var title: String {
        switch prompt.kind {
        case .approval: return "\(bot.title) wants to run something"
        case .clarify, .clarifyBatch: return "\(bot.title) has a question"
        case .secret: return "\(bot.title) needs a secret"
        case .sudo: return "\(bot.title) needs your password"
        }
    }

    @ViewBuilder var content: some View {
        switch prompt.kind {
        case .approval(let command, let description, let choices):
            ApprovalBody(command: command, description: description, choices: choices) { choice in
                Task { await core.answer(prompt, choice: choice) }
            }
        case .clarify(let question, let choices, _):
            ClarifyBody(question: question, choices: choices, onAnswer: { answer in Task { await core.answer(prompt, text: answer) } }) {
                Task { await core.dismiss(prompt) }
            }
        case .clarifyBatch(let questions):
            BatchClarifyBody(questions: questions) { answers in Task { await core.answer(prompt, answers: answers) } } onSkip: {
                Task { await core.dismiss(prompt) }
            }
        case .secret(let text, let envVar):
            SecretBody(label: text, detail: envVar.isEmpty ? nil : "Saved by Hermes as \(envVar)") { value in
                Task { await core.answer(prompt, text: value) }
            } onCancel: {
                Task { await core.dismiss(prompt) }
            }
        case .sudo(let command):
            SecretBody(label: "Password for sudo", detail: command) { value in
                Task { await core.answer(prompt, text: value) }
            } onCancel: {
                Task { await core.dismiss(prompt) }
            }
        }
    }
}

struct ApprovalBody: View {
    let command: String
    let description: String
    let choices: [String]
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(command)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            if !description.isEmpty {
                Text(description).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if choices.contains("once") {
                    Button("Allow once") { onChoose("once") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                if choices.contains("session") {
                    Button("This session") { onChoose("session") }
                }
                if choices.contains("always") {
                    Button("Always") { onChoose("always") }
                }
                Spacer()
                Button("Deny", role: .destructive) { onChoose("deny") }
            }
            .controlSize(.regular)
        }
    }
}

struct ClarifyBody: View {
    let question: String
    let choices: [String]
    let onAnswer: (String) -> Void
    let onSkip: () -> Void
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(text: question)
            if !choices.isEmpty {
                FlowButtons(choices: choices, onPick: onAnswer)
            }
            HStack {
                TextField(choices.isEmpty ? "Your answer" : "Or type an answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !answer.isEmpty { onAnswer(answer) } }
                Button("Send") { onAnswer(answer) }.disabled(answer.isEmpty)
                Button("Skip", action: onSkip)
            }
        }
    }
}

struct BatchClarifyBody: View {
    let questions: [PendingPrompt.Question]
    let onSubmit: ([String: String?]) -> Void
    let onSkip: () -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.question).font(.system(size: 13))
                    if q.choices.isEmpty {
                        TextField("Answer", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 })).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(q.choices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
            }
            HStack {
                Button("Send answers") {
                    var out: [String: String?] = [:]
                    for q in questions { out[q.id] = answers[q.id].flatMap { $0.isEmpty ? nil : $0 } }
                    onSubmit(out)
                }
                .buttonStyle(.borderedProminent)
                Button("Skip", action: onSkip)
            }
        }
    }
}

/// A secure field: the value is sent to Hermes and never shown or kept.
struct SecretBody: View {
    let label: String
    let detail: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13))
            if let detail { Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary) }
            HStack {
                SecureField("Hidden", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Send", action: submit).buttonStyle(.borderedProminent).disabled(value.isEmpty)
                Button("Cancel", action: onCancel)
            }
            Text("Agora sends this straight to Hermes and doesn't keep it.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    func submit() {
        guard !value.isEmpty else { return }
        let v = value
        value = ""
        onSubmit(v)
    }
}

struct FlowButtons: View {
    let choices: [String]
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices, id: \.self) { c in
                Button(c) { onPick(c) }
            }
        }
    }
}
