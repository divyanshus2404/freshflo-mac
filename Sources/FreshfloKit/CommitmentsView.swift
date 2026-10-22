import Combine
import SwiftUI

/// Every action item from every meeting, grouped by when it's due, each linked to the meeting it came from.
struct CommitmentsView: View {
    @Binding var selection: String?
    @ObservedObject private var store = MeetingStore.shared
    @State private var items: [Commitments.Item] = []
    @State private var model: String?
    @State private var organizing = false
    @State private var note: String?
    @State private var mineOnly = true
    @State private var ticked = Commitments.ticked
    /// Drafts waiting for approval: from "Next step" here, or from an agent connected over MCP (a separate process).
    @State private var proposals = AgentInbox.load()
    @State private var reviewing: ActionProposal?
    /// The commitment whose next step is being worked out.
    @State private var thinking: String?
    private let inboxTick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !proposals.isEmpty { inbox }
                    list
                }
                .padding(24)
            }
        }
        .task(id: Commitments.cacheKey(store.meetings)) { await load() }
        .onReceive(inboxTick) { _ in
            let latest = AgentInbox.load()
            if latest != proposals { proposals = latest }
        }
        .sheet(item: $reviewing) { proposal in
            ProposalSheet(proposal: proposal) { done in
                proposals = AgentInbox.load()
                note = done
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Waiting for your approval").font(.headline)
                Text("\(proposals.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(proposals.reversed()) { proposal in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: proposal.kind.icon).foregroundStyle(Color.accentColor).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proposal.title).fontWeight(.medium).lineLimit(2)
                        Text("\(proposal.kind.label) for “\(proposal.commitmentTask)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ModelBadge(credit: proposal.proposedBy)
                    }
                    Spacer()
                    Button("Review…") { reviewing = proposal }
                    Button {
                        AgentInbox.remove(proposal.id)
                        proposals = AgentInbox.load()
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            }
        }
    }

    private func nextStep(_ item: Commitments.Item) async {
        thinking = item.id
        defer { thinking = nil }
        do {
            let proposal = try await CommitmentAgent.propose(item, meetings: store.meetings, settings: .shared)
            AgentInbox.add(proposal)
            proposals = AgentInbox.load()
            reviewing = proposals.first { $0.id == proposal.id }
        } catch where error is CancellationError {
        } catch {
            note = "Couldn't work out a next step: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Open commitments").font(.system(size: 22, design: .serif))
                Spacer()
                Picker("", selection: $mineOnly) {
                    Text("Mine").tag(true)
                    Text("Everyone").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(organizing).help("Read the notes again")
            }
            Text("Every action item from every meeting in one list: duplicates merged, deadlines turned into dates, and items a later meeting says are done marked done.")
                .font(.callout).foregroundStyle(.secondary)
            if organizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(ModelCredit.configured(.shared).map { ModelCredit.parts($0).headline } ?? "The model") is reading \(store.meetings.count) meetings…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let model, !model.isEmpty {
                ModelBadge(credit: model)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    @ViewBuilder private var list: some View {
        let visible = items.filter { !mineOnly || $0.isMine }
        let groups = Dictionary(grouping: visible) { Commitments.bucket($0, ticked: ticked.contains($0.id)) }
        VStack(alignment: .leading, spacing: 22) {
            if visible.isEmpty, !organizing {
                Text(items.isEmpty ? "No action items in your meeting notes yet." : "Nothing assigned to you. Switch to Everyone to see the rest.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Commitments.Bucket.allCases) { bucket in
                if let rows = groups[bucket], !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(bucket.title).font(.headline).foregroundStyle(bucket == .overdue ? Color.red : Color.primary)
                            Text("\(rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ForEach(sorted(rows)) { row($0, bucket: bucket) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sorted(_ rows: [Commitments.Item]) -> [Commitments.Item] {
        rows.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.meetingDate > b.meetingDate
            }
        }
    }

    private func row(_ item: Commitments.Item, bucket: Commitments.Bucket) -> some View {
        let done = bucket == .done
        return HStack(alignment: .top, spacing: 10) {
            Button { toggle(item) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.doneNote != nil)
            .accessibilityLabel(done ? "Done" : "Mark done")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.task).strikethrough(done).foregroundStyle(done ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(item.owner.isEmpty ? "No owner" : item.owner, systemImage: item.owner == "You" ? "person.fill" : "person")
                    if let date = item.dueDate {
                        Label(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
                            .foregroundStyle(bucket == .overdue ? Color.red : Color.secondary)
                    } else if !item.due.isEmpty {
                        Label(item.due, systemImage: "calendar")
                    }
                    Button { selection = item.meetingID } label: {
                        Label("\(item.meetingTitle) (\(item.meetingDate.formatted(date: .abbreviated, time: .omitted)))", systemImage: "doc.text")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
                if !item.alsoIn.isEmpty {
                    Text("Also came up in \(item.alsoIn.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                if let doneNote = item.doneNote {
                    Label(doneNote, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 8)
            if !done {
                if thinking == item.id {
                    ProgressView().controlSize(.small).help("Nemotron is choosing a next step…")
                } else {
                    Button { Task { await nextStep(item) } } label: { Label("Next step", systemImage: "sparkles") }
                        .controlSize(.small)
                        .disabled(thinking != nil)
                        .help("Nemotron drafts the follow-up email, a reminder or a research brief. You approve it before anything happens.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func toggle(_ item: Commitments.Item) {
        if ticked.contains(item.id) { ticked.remove(item.id) } else { ticked.insert(item.id) }
        Commitments.ticked = ticked
    }

    private func load(force: Bool = false) async {
        let meetings = store.meetings
        let key = Commitments.cacheKey(meetings)
        if !force, let cache = Commitments.cache, cache.key == key {
            items = cache.items
            model = cache.model
            return
        }
        // Organised in an earlier session and the notes haven't changed since: no model call needed.
        if !force, let saved = Commitments.loadSaved(), saved.key == key {
            items = saved.items
            model = saved.model
            Commitments.cache = (key, saved.items, saved.model)
            return
        }
        let parsed = Commitments.parse(meetings)
        items = parsed
        model = nil
        note = nil
        guard !parsed.isEmpty else { return }
        guard AppSettings.shared.canUseCloud || AppleModel.isAvailable else {
            note = "Add a model in Settings to merge duplicates, date deadlines and spot finished items."
            return
        }
        organizing = true
        defer { organizing = false }
        do {
            let result = try await Commitments.organize(parsed, meetings: meetings, settings: .shared)
            items = result.items
            model = result.model
            Commitments.cache = (key, result.items, result.model)
            // Agents connected over MCP read this copy instead of asking the model again.
            Commitments.save(.init(key: key, items: result.items, model: result.model))
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
        } catch {
            note = "Showing the items as written in your notes (\(error.localizedDescription))."
        }
    }
}
