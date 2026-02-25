//
//  AppDelegate.swift
//  LumiAgent
//
//  Created by Lumi Agent on 2026-02-18.
//

#if os(macOS)
import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ LumiAgent launched successfully")
        print("📦 Bundle ID: \(Bundle.main.bundleIdentifier ?? "not set")")

        // Configure app
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = LumiServicesProvider.shared
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)

        // Configure main window for glass look
        if let window = NSApp.windows.first {
            setupGlassWindow(window)
        }

        // Set up menu bar icon
        setupMenuBar()

        // Start the iOS remote-control server.
        Task { @MainActor in
            MacRemoteServer.shared.start()
        }
    }

    private func setupGlassWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isOpaque = false
    }

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lumi")!
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.action = #selector(toggleApp)
            button.target = self
        }
        self.statusItem = statusItem
    }

    @objc func toggleApp() {
        if NSApp.windows.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
        } else if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("👋 LumiAgent shutting down")
        Task { @MainActor in MacRemoteServer.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even if all windows closed
        return false
    }
}
#endif
