import AppKit
import ShipModel
import SwiftUI

/// Home (⌂, ⌘0): a quiet clock on the left the way Hark idles, and mission control on the
/// right: a serif greeting over glass panels.
struct HomeView: View {
    let model: AppModel
    /// Fixed time for snapshots.
    var now: Date?

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 0) {
                TimelineView(.everyMinute) { context in
                    ClockColumn(date: now ?? context.date)
                }
                .frame(width: max(260, geometry.size.width * 0.34), alignment: .leading)
                .padding(.leading, 56)
                .accessibilityElement(children: .combine)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.greeting(at: now ?? Date()))
                                .font(Sky.Font.serifL)
                                .foregroundStyle(Sky.ink)
                            Text(model.statusSentence)
                                .font(.system(size: 14))
                                .foregroundStyle(Sky.secondary)
                        }
                        .padding(.top, 28)
                        HomePanels(model: model, width: min(760, geometry.size.width * 0.66 - 80))
                    }
                    .padding(.trailing, 40)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// "Wed / Oct 21 / 3:36 PM" stacked, display 64/60, −2 % tracking.
struct ClockColumn: View {
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: -16) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
            Text(date.formatted(.dateTime.month(.abbreviated).day()))
            Text(date.formatted(.dateTime.hour().minute()))
        }
        .font(Sky.Font.displayXL)
        .tracking(-1.3)
        .foregroundStyle(Sky.ink)
        .monospacedDigit()
    }
}

/// Two-column masonry of glass panels.
struct HomePanels: View {
    let model: AppModel
    let width: CGFloat
    @AppStorage("home.hiddenPanels") private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        let column = max(280, (width - 14) / 2)
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                if !hidden.contains("needs") { NeedsYouPanel(model: model) }
                if !hidden.contains("working") { WorkingNowPanel(model: model) }
            }
            .frame(width: column)
            VStack(spacing: 14) {
                if !hidden.contains("today") { TodayPanel(model: model) }
                if !hidden.contains("ports") { PortsPanel(model: model) }
                if !hidden.contains("elsewhere") { ElsewherePanel(model: model) }
                createPanel
            }
            .frame(width: column)
        }
    }

    private var createPanel: some View {
        Menu {
            ForEach([("needs", "Needs you"), ("working", "Working now"), ("today", "Today"), ("ports", "Ports"), ("elsewhere", "Elsewhere")], id: \.0) { key, title in
                Button {
                    var set = hidden
                    if set.contains(key) { set.remove(key) } else { set.insert(key) }
                    hiddenRaw = set.sorted().joined(separator: ",")
                } label: {
                    if hidden.contains(key) { Text(title) } else { Label(title, systemImage: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .regular))
                Text("Create a new panel").font(.system(size: 14))
            }
            .foregroundStyle(Sky.ink.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .glassPanel()
            .contentShape(RoundedRectangle(cornerRadius: Sky.radiusPanel))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A glass panel with a small header (icon + title), like Hark's weather card.
struct HomePanel<Content: View>: View {
    let symbol: String
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let trailing {
                    Text(trailing).font(Sky.Font.meta).foregroundStyle(Sky.tertiary)
                }
            }
            .foregroundStyle(Sky.ink.opacity(0.78))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

struct NeedsYouPanel: View {
    let model: AppModel

    var body: some View {
        let items = model.sessions
            .filter { $0.state.isLive && ($0.needsYou || $0.state.isError || ($0.unread && $0.state == .idle)) }
            .sorted { $0.sidebarPriority < $1.sidebarPriority }
        HomePanel(symbol: "bell", title: "Needs you", trailing: items.isEmpty ? nil : "\(items.count)") {
            if items.isEmpty {
                Text("Nothing needs you.")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(Sky.secondary)
                    .padding(.vertical, 6)
            } else {
                FannedStack(items: items) { session in
                    AttentionCard(model: model, session: session)
                }
            }
        }
    }
}

/// A white card for one session that wants you: what it is, what it said, what it asks.
struct AttentionCard: View {
    let model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title ?? session.kind.displayName)
                        .font(Sky.Font.title)
                        .foregroundStyle(Sky.ink)
                        .lineLimit(1)
                    Text(locationLine)
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(session.state.shortLabel)
                    .font(Sky.Font.meta)
                    .foregroundStyle(session.needsYou ? Sky.attention : session.state.isError ? Sky.danger : Sky.secondary)
            }
            if session.pendingPermission != nil || model.recentlyResolved[session.id] != nil {
                PermissionMorph(request: session.pendingPermission, resolved: model.recentlyResolved[session.id]) { request, decision in
                    model.resolvePermission(request, decision: decision)
                }
            } else if let line = session.lastAssistantMessage ?? session.displayLine {
                Text(line)
                    .font(Sky.Font.body)
                    .foregroundStyle(Sky.ink.opacity(0.8))
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: 18)
        .onTapGesture {
            if let surface = session.surface { model.focusSurface(surface) }
        }
    }

    private var locationLine: String {
        let workspace = session.surface.flatMap { model.workspace(containing: $0)?.name }
        return [workspace ?? session.hostApp, PathDisplay.short(session.cwd)].compactMap { $0 }.joined(separator: " · ")
    }
}

struct WorkingNowPanel: View {
    let model: AppModel

    var body: some View {
        let working = model.sessions.filter(\.state.isWorking).sorted { $0.lastActivity > $1.lastActivity }
        HomePanel(symbol: "waveform", title: "Working now", trailing: working.isEmpty ? nil : "\(working.count)") {
            if working.isEmpty {
                Text("No agent is working.")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(Sky.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(working.prefix(3)) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                AgentStatusGlyph(kind: session.kind, state: session.state, size: 12)
                                Text(session.title ?? session.kind.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Sky.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(Format.elapsed(since: session.startedAt))
                                    .font(Sky.Font.meta)
                                    .foregroundStyle(Sky.tertiary)
                            }
                            BubbleTail(session: session, replyLines: 3)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let surface = session.surface { model.focusSurface(surface) }
                        }
                    }
                }
            }
        }
    }
}

struct TodayPanel: View {
    let model: AppModel

    var body: some View {
        let totals = model.todayTotals
        HomePanel(symbol: "sun.max", title: "Today") {
            HStack(spacing: 8) {
                tile("Tokens", Format.tokens(totals.tokens))
                tile("Spent", Format.cost(totals.cost))
                tile("Sessions", "\(totals.sessions)")
            }
            Text("Estimated from transcripts on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Sky.tertiary)
        }
    }

    /// Hark's weather tiles: label over a big tabular number.
    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.secondary)
            Text(value)
                .font(.system(size: 24, weight: .regular).monospacedDigit())
                .foregroundStyle(Sky.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Sky.radiusControl, style: .continuous).fill(Sky.bubbleUser))
    }
}

struct PortsPanel: View {
    let model: AppModel

    var body: some View {
        HomePanel(symbol: "network", title: "Ports") {
            if model.ports.isEmpty {
                Text("No dev servers listening.")
                    .font(.system(size: 13))
                    .foregroundStyle(Sky.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.ports.enumerated()), id: \.element.id) { index, port in
                        if index > 0 { Rectangle().fill(Sky.hairline).frame(height: 1) }
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "localhost:" + String(port.port))
                                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Sky.ink)
                                Text([port.process, port.workspaceName].compactMap { $0 }.joined(separator: " · "))
                                    .font(Sky.Font.meta)
                                    .foregroundStyle(Sky.tertiary)
                            }
                            Spacer()
                            Button("Open") {
                                if let url = port.url { model.openBrowserSplit(url: url) }
                            }
                            .buttonStyle(SecondaryPillStyle(height: 26))
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

struct ElsewherePanel: View {
    let model: AppModel

    var body: some View {
        let external = model.externalSessions.sorted { $0.sidebarPriority < $1.sidebarPriority }
        HomePanel(symbol: "macwindow.on.rectangle", title: "Elsewhere", trailing: external.isEmpty ? nil : "\(external.count)") {
            if external.isEmpty {
                Text("No agents outside Mothership.")
                    .font(.system(size: 13))
                    .foregroundStyle(Sky.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(external.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Rectangle().fill(Sky.hairline).frame(height: 1) }
                        HStack(spacing: 10) {
                            AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, size: 13)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title ?? session.kind.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Sky.ink)
                                    .lineLimit(1)
                                Text("\(session.hostApp ?? "Terminal") · \(PathDisplay.short(session.cwd))")
                                    .font(Sky.Font.meta)
                                    .foregroundStyle(Sky.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(session.state.shortLabel)
                                .font(Sky.Font.meta)
                                .foregroundStyle(session.needsYou ? Sky.attention : Sky.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { HostApp.reveal(session.hostApp) }
                    }
                }
            }
        }
    }
}

enum HostApp {
    /// Brings the app hosting an external session to the front.
    @MainActor
    static func reveal(_ name: String?) {
        guard let name else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?
            .activate()
    }
}
