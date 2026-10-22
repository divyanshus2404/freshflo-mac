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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { list.padding(24) }
        }
        .task(id: Commitments.cacheKey(store.meetings)) { await load() }
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
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
        } catch {
            note = "Showing the items as written in your notes (\(error.localizedDescription))."
        }
    }
}
