#if os(macOS)
import AppKit

@MainActor
final class LumiServicesProvider: NSObject {
    static let shared = LumiServicesProvider()
    private var servicesEnabled: Bool {
        UserDefaults.standard.bool(forKey: "settings.enableSystemServices")
            || UserDefaults.standard.object(forKey: "settings.enableSystemServices") == nil
    }

    @objc func extendSelectedText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard servicesEnabled else {
            error.pointee = "Lumi Services are disabled in Settings -> Integrations." as NSString
            return
        }
        transformTextFromPasteboard(pboard, action: .extend, error: error)
    }

    @objc func correctGrammar(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard servicesEnabled else {
            error.pointee = "Lumi Services are disabled in Settings -> Integrations." as NSString
            return
        }
        transformTextFromPasteboard(pboard, action: .grammar, error: error)
    }

    @objc func autoResolveText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard servicesEnabled else {
            error.pointee = "Lumi Services are disabled in Settings -> Integrations." as NSString
            return
        }
        transformTextFromPasteboard(pboard, action: .autoResolve, error: error)
    }

    @objc func cleanDesktopService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard servicesEnabled else {
            error.pointee = "Lumi Services are disabled in Settings -> Integrations." as NSString
            return
        }
        guard let appState = AppState.shared else {
            error.pointee = "Lumi is not ready." as NSString
            return
        }
        appState.sendQuickAction(type: .cleanDesktop)
    }

    private func transformTextFromPasteboard(
        _ pboard: NSPasteboard,
        action: AppState.TextAssistAction,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let appState = AppState.shared else {
            error.pointee = "Lumi is not ready." as NSString
            return
        }
        guard let source = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            error.pointee = "No selected text found." as NSString
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var transformed: String?
        var failure: String?

        // Perform the work on the MainActor but wait on a background queue to avoid deadlocking the main thread
        Task { @MainActor in
            defer { semaphore.signal() }
            do {
                transformed = try await appState.rewriteText(source, action: action)
            } catch {
                failure = error.localizedDescription
            }
        }

        // Wait on a background queue to avoid blocking the MainActor if this is called from there
        let result = semaphore.wait(timeout: .now() + 60)
        
        if result == .timedOut {
            error.pointee = "Text transformation timed out." as NSString
            return
        }

        if let transformed, !transformed.isEmpty {
            pboard.clearContents()
            pboard.setString(transformed, forType: .string)
            return
        }

        error.pointee = (failure ?? "Text transformation failed.") as NSString
    }
}
#endif
