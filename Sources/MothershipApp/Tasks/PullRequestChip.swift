import GitKit
import SwiftUI

/// `#128 ✓` on sidebar rows and in pane chrome: the PR number and one mark for where it
/// stands (ink ✓ checks pass, ✗ failing, ● pending or waiting on review), dashed when
/// draft, quiet when merged. Click opens it in a browser split; hover shows the details.
struct PullRequestChip: View {
    let status: PullRequestStatus
    /// On a selected (ink or frosted) row.
    var onSelection = false
    let open: () -> Void

    @State private var hovering = false
    @State private var showsCard = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Text(verbatim: "#" + String(status.number))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor)
                PullRequestMark(status: status, onSelection: onSelection, size: 8.5)
            }
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule(style: .continuous).fill(fill))
            .overlay {
                if status.state == .draft {
                    Capsule(style: .continuous).strokeBorder(textColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled, hovering { showsCard = true }
                }
            } else {
                showsCard = false
            }
        }
        .popover(isPresented: $showsCard, arrowEdge: .bottom) {
            PullRequestCard(status: status)
        }
        .accessibilityLabel("Pull request \(status.number), \(PullRequestCard.summary(status))")
    }

    private var fill: Color {
        if onSelection { return Sky.onSelection.opacity(hovering ? 0.2 : 0.14) }
        return hovering ? Sky.ink.opacity(0.1) : Sky.recess
    }

    private var textColor: Color {
        if onSelection { return Sky.onSelection.opacity(status.state == .merged || status.state == .closed ? 0.6 : 0.85) }
        switch status.state {
        case .merged, .closed, .draft: return Sky.tertiary
        case .open: return Sky.ink.opacity(0.78)
        }
    }
}

/// The single mark after the number.
struct PullRequestMark: View {
    let status: PullRequestStatus
    var onSelection = false
    var size: CGFloat = 9

    var body: some View {
        switch status.state {
        case .merged:
            Text("merged").font(.system(size: size + 1, weight: .medium)).foregroundStyle(base.opacity(0.55))
        case .closed:
            Text("closed").font(.system(size: size + 1, weight: .medium)).foregroundStyle(base.opacity(0.45))
        case .open, .draft:
            switch status.checks {
            case .failing:
                Image(systemName: "xmark").font(.system(size: size - 0.5, weight: .bold)).foregroundStyle(Sky.danger)
            case .pending:
                Circle().fill(base.opacity(0.45)).frame(width: size - 2, height: size - 2)
            case .passing, .none:
                if status.review == .changesRequested || status.review == .reviewRequired {
                    Circle().fill(Sky.attention).frame(width: size - 2, height: size - 2)
                } else if status.checks == .passing {
                    Image(systemName: "checkmark").font(.system(size: size - 0.5, weight: .bold)).foregroundStyle(base.opacity(0.85))
                } else {
                    Circle().strokeBorder(base.opacity(0.4), lineWidth: 1).frame(width: size - 2, height: size - 2)
                }
            }
        }
    }

    private var base: Color { onSelection ? Sky.onSelection : Sky.ink }
}

/// Hover details: title, state, checks and review.
struct PullRequestCard: View {
    let status: PullRequestStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "#" + String(status.number)).font(Sky.Font.meta).foregroundStyle(Sky.secondary)
                Text(stateTitle).font(Sky.Font.label).foregroundStyle(Sky.secondary)
            }
            Text(status.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Sky.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                row("Checks", checksText, mark: AnyView(PullRequestMark(status: PullRequestStatus(
                    number: status.number, title: status.title, url: status.url, state: .open, checks: status.checks, review: .none
                ))))
                row("Review", reviewText, mark: nil)
            }
            Text(host)
                .font(Sky.Font.meta)
                .foregroundStyle(Sky.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, mark: AnyView?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Sky.tertiary).frame(width: 52, alignment: .leading)
            Group {
                if let mark { mark } else { Color.clear }
            }
            .frame(width: 12, height: 12)
            Text(value).font(.system(size: 12.5)).foregroundStyle(Sky.ink.opacity(0.85))
        }
    }

    private var stateTitle: String {
        switch status.state {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    private var checksText: String {
        switch status.checks {
        case .passing: "All checks passing"
        case .failing: "Some checks failing"
        case .pending: "Checks running"
        case .none: "No checks"
        }
    }

    private var reviewText: String {
        switch status.review {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review requested"
        case .none: "No reviews yet"
        }
    }

    private var host: String {
        URL(string: status.url).map { ($0.host ?? "") + $0.path } ?? status.url
    }

    static func summary(_ status: PullRequestStatus) -> String {
        let card = PullRequestCard(status: status)
        return "\(card.stateTitle), \(card.checksText.lowercased()), \(card.reviewText.lowercased())"
    }
}
