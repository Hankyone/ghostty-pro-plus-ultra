import SwiftUI

/// A pill-shaped button that displays update status and acts directly on click.
/// No popover — the pill itself is the action button:
///   - "Update Available" → click to start install
///   - "Downloading/Preparing" → shows progress (click to cancel)
///   - "Install and Relaunch" → click to restart
///   - "Update Failed" → click to retry
///   - "No Updates" → auto-dismisses after 5s
struct UpdatePill: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel

    /// Task for auto-dismissing the "No Updates" state
    @State private var resetTask: Task<Void, Never>?

    /// The font used for the pill text
    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if !model.state.isHidden {
            pillButton
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .onChange(of: model.state) { newState in
                    resetTask?.cancel()
                    if case .notFound(let notFound) = newState {
                        resetTask = Task { [weak model] in
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled, case .notFound? = model?.state else { return }
                            model?.state = .idle
                            notFound.acknowledgement()
                        }
                    } else {
                        resetTask = nil
                    }
                }
        }
    }

    /// The pill-shaped button view that displays the update badge and text
    @ViewBuilder
    private var pillButton: some View {
        Button(action: pillAction, label: {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)

                Text(pillText)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
            .contentShape(Capsule())
        })
        .buttonStyle(.plain)
        .help(pillText)
        .accessibilityLabel(pillText)
    }

    /// The text shown on the pill — changes based on state to indicate the action.
    private var pillText: String {
        switch model.state {
        case .updateAvailable(let update):
            return "Install \(update.appcastItem.displayVersionString)"
        case .installing:
            return "Relaunch to Update"
        case .error:
            return "Retry Update"
        default:
            return model.text
        }
    }

    /// The action performed when the pill is clicked — depends on the current state.
    private func pillAction() {
        switch model.state {
        case .notFound(let notFound):
            model.state = .idle
            notFound.acknowledgement()

        case .updateAvailable(let update):
            // Start the download and install
            update.reply(.install)

        case .installing(let installing):
            // Restart the app to complete the update
            installing.retryTerminatingApplication()

        case .error(let error):
            // Retry the update
            error.retry()

        case .checking(let checking):
            // Cancel the check
            checking.cancel()

        case .downloading(let download):
            // Cancel the download
            download.cancel()

        default:
            break
        }
    }

    /// Calculated width for the text to prevent resizing during progress updates.
    /// Uses the wider of maxWidthText and the actual pillText so that state-specific
    /// overrides like "Relaunch to Update" are never truncated.
    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        return [model.maxWidthText, pillText]
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max()
    }
}
