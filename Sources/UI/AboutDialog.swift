import Cocoa

enum AboutDialog {
    enum Action {
        case openGitHub
        case dismiss
    }

    static func present(version: String?) -> Action {
        let subtitle: String
        if let version, !version.isEmpty {
            subtitle = "\(AppStrings.About.title) v\(version)"
        } else {
            subtitle = AppStrings.About.title
        }

        let message = "\(subtitle)\n\n\(AppStrings.About.shortcutsTitle)\n\(AppStrings.About.triggerShortcut)\n\(AppStrings.About.cancelShortcut)"

        let alert = NSAlert()
        alert.messageText = AppStrings.Menu.about
        alert.informativeText = message
        alert.addButton(withTitle: AppStrings.About.github)
        alert.addButton(withTitle: AppStrings.About.dismiss)

        return alert.runModal() == .alertFirstButtonReturn ? .openGitHub : .dismiss
    }
}
