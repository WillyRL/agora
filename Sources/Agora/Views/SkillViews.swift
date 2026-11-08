import AgoraCore
import SwiftUI

/// The Bot editor's Skills section: this Bot's skills with on/off switches, plus adding one from the
/// skills hub or writing a new one. Changes apply right away and touch this Bot only.
struct BotSkillsSection: View {
    @Environment(AgoraCore.self) private var core
    let bot: String
    let botTitle: String
    @State private var skills: [Skill]?
    @State private var error: String?
    @State private var filter = ""
    @State private var showHub = false
    @State private var editing: SkillSheet?
    @State private var busy: Set<String> = []

    enum SkillSheet: Identifiable {
        case new
        case edit(Skill)
        var id: String {
            if case .edit(let s) = self { return "edit:" + s.name }
            return "new"
        }
    }

    var body: some View {
        Field("Skills") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let skills {
                        Text("\(skills.count) skills · \(skills.filter(\.enabled).count) on")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Get from Hub…") { showHub = true }
                    Button("New Skill…") { editing = .new }
                }
                .controlSize(.small)

                if let skills {
                    TextField("Filter skills", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    list(skills)
                } else if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Skills are instructions \(botTitle) loads when a task calls for them. Each Bot has its own; turning one off here doesn't touch other Bots.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showHub) {
            SkillHubSheet(bot: bot, botTitle: botTitle, installed: Set(skills?.map(\.name) ?? [])) { Task { await load() } }
        }
        .sheet(item: $editing) { sheet in
            switch sheet {
            case .new: NewSkillSheet(bot: bot, categories: Array(Set(skills?.map(\.category) ?? [])).sorted()) { Task { await load() } }
            case .edit(let skill): SkillEditorSheet(bot: bot, skill: skill) { Task { await load() } }
            }
        }
    }

    func list(_ skills: [Skill]) -> some View {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? skills : skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) || $0.category.contains(q) }
        let groups = Dictionary(grouping: shown, by: \.category).sorted { $0.key < $1.key }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    Text(q.isEmpty ? "No skills yet." : "No skills match “\(filter)”.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                }
                ForEach(groups, id: \.key) { category, items in
                    Text(category.replacingOccurrences(of: "-", with: " ").uppercased())
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.top, 10).padding(.bottom, 3).padding(.horizontal, 10)
                    ForEach(items) { skill in
                        SkillRow(skill: skill, busy: busy.contains(skill.name)) { on in
                            Task { await toggle(skill, on: on) }
                        } edit: {
                            editing = .edit(skill)
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(height: 300)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }

    func load() async {
        do {
            skills = try await core.skills(bot: bot)
            error = nil
        } catch {
            if skills == nil { self.error = "Couldn't load skills: \(error.localizedDescription)" }
        }
    }

    func toggle(_ skill: Skill, on: Bool) async {
        busy.insert(skill.name)
        defer { busy.remove(skill.name) }
        do {
            try await core.setSkill(skill.name, enabled: on, bot: bot)
            if let i = skills?.firstIndex(where: { $0.name == skill.name }) { skills?[i].enabled = on }
        } catch {
            core.notice = "Couldn't turn \(skill.name) \(on ? "on" : "off"): \(error.localizedDescription)"
        }
    }
}

struct SkillRow: View {
    let skill: Skill
    let busy: Bool
    let toggle: (Bool) -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { skill.enabled }, set: toggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(busy)
            Text(skill.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(skill.enabled ? .primary : .secondary)
            if skill.origin == .hub { Badge("hub") }
            Text(skill.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).help(skill.description)
            Spacer(minLength: 4)
            Button(action: edit) {
                Image(systemName: "square.and.pencil").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("View or edit this skill")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

// MARK: Editing

/// A skill's SKILL.md, editable as is.
struct SkillEditorSheet: View {
    @Environment(AgoraCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    let bot: String
    let skill: Skill
    @State private var content = ""
    @State private var original: String?
    @State private var error: String?
    @State private var saving = false
    @State private var removing = false
    @State private var confirmRemove = false
    var changed: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(skill.name).font(.system(size: 15, weight: .semibold))
                if skill.origin == .hub { Badge("hub") }
                if skill.origin == .bundled { Badge("built in") }
            }
            Text(skill.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if original == nil, error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardBackground))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            }
            if skill.origin != .local {
                Text("Editing a \(skill.origin == .hub ? "hub" : "built-in") skill keeps your changes, but updates to it from \(skill.origin == .hub ? "the hub" : "Hermes") won't replace them.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
            HStack {
                if skill.origin == .hub {
                    Button(removing ? "Uninstalling…" : "Uninstall…", role: .destructive) { confirmRemove = true }
                        .disabled(removing || saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || original == nil || content == original)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .confirmationDialog("Uninstall \(skill.name) from this Bot?", isPresented: $confirmRemove) {
            Button("Uninstall", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Other Bots keep their own copy. You can install it again from the hub.")
        }
        .task {
            do {
                content = try await core.skillContent(skill.name, bot: bot)
                original = content
            } catch {
                self.error = "Couldn't open \(skill.name): \(error.localizedDescription)"
            }
        }
    }

    func remove() async {
        removing = true
        defer { removing = false }
        do {
            try await core.uninstallSkill(skill.name, bot: bot)
            changed()
            dismiss()
        } catch {
            self.error = "Couldn't uninstall: \(error.localizedDescription)"
        }
    }

    func save() async {
        saving = true
        defer { saving = false }
        do {
            try await core.saveSkill(skill.name, content: content, bot: bot)
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Writes a new skill for one Bot from plain fields.
struct NewSkillSheet: View {
    @Environment(AgoraCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    let bot: String
    let categories: [String]
    let created: () -> Void
    @State private var title = ""
    @State private var description = ""
    @State private var category = ""
    @State private var instructions = ""
    @State private var error: String?
    @State private var saving = false

    var name: String { Skill.slug(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Skill").font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("silver-weekly", text: $title).textFieldStyle(.roundedBorder)
                        if !title.isEmpty, name != title {
                            Text("Saved as “\(name)”").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("When to use")
                    TextField("Weekly silver chart with levels, every Sunday before the reopen", text: $description).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Category")
                    HStack {
                        TextField("optional", text: $category).textFieldStyle(.roundedBorder).frame(width: 180)
                        if !categories.isEmpty {
                            Menu("Pick") {
                                ForEach(categories, id: \.self) { c in Button(c) { category = c } }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .font(.system(size: 12.5))
            Text("Instructions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $instructions)
                .font(.system(size: 12.5))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Text("Write the steps the way you'd brief a colleague. The Bot reads “When to use” to decide when to load the skill.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Creating…" : "Create Skill") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.isEmpty || description.trimmingCharacters(in: .whitespaces).isEmpty
                        || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    func create() async {
        saving = true
        defer { saving = false }
        do {
            let doc = Skill.document(name: name, description: description, instructions: instructions)
            try await core.createSkill(name, content: doc, category: Skill.slug(category), bot: bot)
            created()
            dismiss()
        } catch {
            self.error = "Couldn't create the skill: \(error.localizedDescription)"
        }
    }
}

// MARK: Hub

/// Searches the skills hub and installs a skill for this Bot only.
struct SkillHubSheet: View {
    @Environment(AgoraCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    let bot: String
    let botTitle: String
    let installed: Set<String>
    let changed: () -> Void
    @State private var query = ""
    @State private var results: [HubSkill]?
    @State private var searching = false
    @State private var installing: String?
    @State private var done: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get a Skill for \(botTitle)").font(.system(size: 15, weight: .semibold))
            HStack {
                TextField("Search the skills hub (e.g. powerpoint, tradingview, aws)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Group {
                if searching {
                    ProgressView("Searching…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let results {
                    if results.isEmpty {
                        Text("Nothing found for “\(query)”.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(results) { hit in row(hit) }.listStyle(.inset)
                    }
                } else {
                    Text("Skills from the hub are scanned by Hermes before they're installed, and added to \(botTitle) only. Prefer official ones; community skills are written by anyone.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }

    func row(_ hit: HubSkill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.name).font(.system(size: 12.5, weight: .medium))
                    Badge(hit.source)
                    if hit.trust == "community" {
                        Text("community").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    } else {
                        Text(hit.trust == "builtin" ? "official" : hit.trust).font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                    }
                }
                Text(hit.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                Text(hit.identifier).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if hit.installed || installed.contains(hit.name) || done.contains(hit.id) {
                Label("Installed", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(.green)
            } else if installing == hit.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { Task { await install(hit) } }.controlSize(.small).disabled(installing != nil)
            }
        }
        .padding(.vertical, 3)
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        error = nil
        defer { searching = false }
        do {
            results = try await core.searchSkillHub(q, bot: bot)
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
        }
    }

    func install(_ hit: HubSkill) async {
        installing = hit.id
        error = nil
        defer { installing = nil }
        do {
            try await core.installSkill(hit, bot: bot)
            done.insert(hit.id)
            changed()
        } catch {
            self.error = "Couldn't install \(hit.name): \(error.localizedDescription)"
        }
    }
}
