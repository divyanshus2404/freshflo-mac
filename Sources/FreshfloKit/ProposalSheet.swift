import SwiftUI

/// Review one proposed action before anything happens: edit it, approve it (Mail draft, reminder, copy), or dismiss it.
struct ProposalSheet: View {
    @State var proposal: ActionProposal
    /// Called after approving or dismissing, with what happened ("Added to Reminders.") or nil.
    let onFinish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(proposal.kind.label, systemImage: proposal.kind.icon).font(.title3.weight(.semibold))
                Spacer()
                ModelBadge(credit: proposal.proposedBy)
            }
            Label("For “\(proposal.commitmentTask)”", systemImage: "checklist").font(.callout).foregroundStyle(.secondary)
            editor
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Text("Nothing is sent or saved until you approve.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss", role: .destructive) {
                    AgentInbox.remove(proposal.id)
                    onFinish(nil)
                    dismiss()
                }
                Spacer()
                Button("Not now") { dismiss() }
                Button { approve() } label: {
                    if running { ProgressView().controlSize(.small) } else { Text(proposal.kind.approveLabel) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running || proposal.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    @ViewBuilder private var editor: some View {
        switch proposal.kind {
        case .email:
            TextField("To", text: $proposal.to, prompt: Text("name@company.com"))
            TextField("Subject", text: $proposal.title)
            TextEditor(text: $proposal.body).font(.body).frame(minHeight: 220).border(Color.secondary.opacity(0.25))
        case .reminder:
            TextField("Reminder", text: $proposal.title)
            HStack {
                Toggle("Due", isOn: Binding(get: { proposal.due != nil }, set: { proposal.due = $0 ? (proposal.due ?? Date()) : nil }))
                if let due = proposal.due {
                    DatePicker("", selection: Binding(get: { due }, set: { proposal.due = $0 }), displayedComponents: .date).labelsHidden()
                }
            }
            TextEditor(text: $proposal.body).font(.body).frame(minHeight: 80).border(Color.secondary.opacity(0.25))
        case .research, .note:
            TextField("Title", text: $proposal.title)
            ScrollView {
                Text(proposal.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 300)
            if !proposal.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(proposal.sources.enumerated()), id: \.offset) { index, source in
                        if let url = URL(string: source) {
                            Link("[\(index + 1)] \(url.host ?? source)", destination: url).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func approve() {
        running = true
        error = nil
        Task {
            do {
                let done = try await ActionRunner.approve(proposal)
                AgentInbox.remove(proposal.id)
                onFinish(done)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
