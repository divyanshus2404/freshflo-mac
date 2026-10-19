import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, appearance, tone, dictionary, snippets, history, meetings, advanced
}

final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var query = ""
}

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter

    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings", text: $router.query).textFieldStyle(.plain).focused($searchFocused)
                if !router.query.isEmpty {
                    Button { router.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .padding(.horizontal, 12).padding(.top, 10)
            .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
            if router.query.isEmpty {
                tabs
            } else {
                SettingsSearchResults(query: router.query) { hit in
                    if hit.advanced { settings.showAdvanced = true }
                    router.tab = hit.tab
                    router.query = ""
                }
            }
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    private var tabs: some View {
        TabView(selection: $router.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            ToneTab().tabItem { Label("Style", systemImage: "textformat") }.tag(SettingsTab.tone)
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(SettingsTab.dictionary)
            SnippetsTab().tabItem { Label("Snippets", systemImage: "text.badge.plus") }.tag(SettingsTab.snippets)
            HistoryTab().tabItem { Label("History", systemImage: "clock") }.tag(SettingsTab.history)
            MeetingsTab().tabItem { Label("Meetings", systemImage: "person.2.wave.2") }.tag(SettingsTab.meetings)
            if settings.showAdvanced {
                AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }.tag(SettingsTab.advanced)
            }
        }
        .padding(12)
    }
}
