import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedId: String?
    @State private var showSettings = false
    @State private var showCoach = false
    @State private var showInfo = false
    @State private var homeHint = false

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                TimelineScreen(selectedId: $selectedId, openCoach: { showCoach = true }, openInfo: { showInfo = true })
                    .padding(.top, 12)
                    .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            WhoopDock()
                .padding(.bottom, 4)
        }
        .sheet(isPresented: Binding(get: { selectedId != nil }, set: { if !$0 { selectedId = nil } })) {
            EventSheet(selectedId: $selectedId)
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
        }
        .sheet(isPresented: $showCoach) {
            InsightsScreen(openEvent: { id in
                // Let Insights finish closing before the event sheet opens.
                showCoach = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { selectedId = id }
            })
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.bgTop)
        }
        .sheet(isPresented: $showInfo) {
            StressInfoSheet(isDemo: store.calendarSource == "Demo calendar" || store.healthSource == "demo heart rate")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.bgTop)
        }
        .alert("This page opens from WHOOP Home.", isPresented: $homeHint) { Button("OK", role: .cancel) {} }
        .onReceive(minuteTimer) { _ in store.tick() }
    }

    private var header: some View {
        @Bindable var store = store
        return VStack(spacing: 6) {
            NavBar(title: "CONTEXT", back: { homeHint = true }) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 20)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Data sources")
            }
            DateNav(
                label: store.dayLabel,
                canGoBack: store.dayOffset < AppStore.historyDays - 1,
                canGoForward: store.dayOffset > 0,
                back: { store.dayOffset += 1 },
                forward: { store.dayOffset -= 1 }
            )
            TopTabs()
        }
        .padding(.top, 4)
    }
}

/// What the (i) next to the gauge explains.
struct StressInfoSheet: View {
    /// Demo calendar or heart rate in use: say plainly that what's on screen is mocked up.
    var isDemo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HOW STRESS IS SCORED").caps(13)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            if isDemo {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MOCK-UP DATA").caps(11)
                    Text("Everything here is a mock-up: the events, heart rate and stress scores are generated demo data, not real readings. Connect your own data from the gear menu.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.indigo.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.indigo, lineWidth: 1))
            }
            Group {
                Text("Each minute, your heart rate is compared with your resting baseline for the day (the lowest 10% of your awake readings). 40% or more above baseline is the top of WHOOP's 0–3 stress scale.")
                Text("An event's score is the average over its minutes. Workouts are scored but left out of stress labels, since a higher heart rate there is effort. Free time between events is grouped into Unscheduled stretches you can name.")
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.white.opacity(0.85))
            .lineSpacing(3)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
    }
}

/// Where the data comes from, and the export for the ML model (behind the gear icon).
struct SettingsSheet: View {
    @Environment(AppStore.self) private var store
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DATA SOURCES").caps(13)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 6)
            Text(store.sourceLabel)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            StatGroup {
                source("calendar", "CALENDAR", store.calendarConnected) { try await store.connectCalendar() }
                source("heart", "APPLE HEALTH", store.healthSource.hasPrefix("Apple")) { try await store.connectHealth() }
                ShareLink(item: CSVExport { store.exportCSV }, preview: SharePreview("events_labeled.csv")) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.muted).frame(width: 20)
                        Text("EXPORT LABELS").caps(11)
                        Spacer()
                        Text("CSV").caps(11, color: Theme.muted)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, -Theme.gutter)

            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.red)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
    }

    private func source(_ icon: String, _ label: String, _ connected: Bool, connect: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                do { try await connect(); message = nil } catch { message = error.localizedDescription }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 20)
                Text(label).caps(11)
                Spacer()
                Text(connected ? "CONNECTED" : "CONNECT").caps(11, color: connected ? Theme.green : Theme.muted)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The labeled CSV for ml/train.py, written to a file only when shared.
struct CSVExport: Transferable {
    let text: () -> String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("events_labeled.csv")
            try export.text().write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
