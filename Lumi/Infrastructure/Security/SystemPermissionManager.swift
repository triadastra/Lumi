#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement
import AVFoundation
import Combine

@MainActor
final class SystemPermissionManager: ObservableObject {
    static let shared = SystemPermissionManager()
    
    @Published var isAccessibilityGranted = false
    @Published var isScreenRecordingGranted = false
    @Published var isFullDiskAccessGranted = false
    @Published var isMicrophoneGranted = false
    @Published var isCameraGranted = false
    @Published var isHelperInstalled = false
    
    private init() {
        refreshAll()
    }
    
    func refreshAll() {
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        checkMicrophone()
        checkCamera()
        checkHelperStatus()
    }
    
    // MARK: - Accessibility
    
    func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    
    // MARK: - Screen Recording
    
    func checkScreenRecording() {
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
    }
    
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    
    // MARK: - Full Disk Access
    
    func checkFullDiskAccess() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Messages/chat.db").path
        isFullDiskAccessGranted = FileManager.default.isReadableFile(atPath: path)
    }
    
    func requestFullDiskAccess() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    // MARK: - Microphone

    func checkMicrophone() {
        isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophone() {
        guard hasUsageDescription("NSMicrophoneUsageDescription") else {
            openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                self.isMicrophoneGranted = granted
            }
        }
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - Camera

    func checkCamera() {
        isCameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestCamera() {
        guard hasUsageDescription("NSCameraUsageDescription") else {
            openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                self.isCameraGranted = granted
            }
        }
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    // MARK: - Privileged Helper

    func checkHelperStatus() {
        let helperPath = "/Library/PrivilegedHelperTools/com.lumiagent.helper"
        isHelperInstalled = FileManager.default.fileExists(atPath: helperPath)
    }

    func installHelper() {
        // Modern approach using SMAppService (requires app to be in /Applications)
        // For development, we'll just open the Security settings where user might need to approve
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Security")
    }

    // MARK: - Manual Privacy Panes

    func requestAutomation() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    func requestInputMonitoring() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func requestFullAccess() {
        refreshAll()

        // Only trigger prompts for permissions that are currently missing.
        if !isAccessibilityGranted {
            requestAccessibility()
        }
        if !isScreenRecordingGranted {
            requestScreenRecording()
        }
        if !isMicrophoneGranted {
            requestMicrophone()
        }
        if !isCameraGranted {
            requestCamera()
        }

        // Open only the manual panes that still need user action.
        var manualPanes: [String] = []
        if !isFullDiskAccessGranted {
            manualPanes.append("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }

        // Automation/Input Monitoring are app-specific toggles; show panes only
        // when core access is not yet fully enabled.
        if !isAccessibilityGranted || !isScreenRecordingGranted {
            manualPanes.append("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            manualPanes.append("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            manualPanes.append("x-apple.systempreferences:com.apple.preference.security?Privacy_Security")
        }

        for (index, pane) in manualPanes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(index + 1) * 0.7)) { [weak self] in
                self?.openSystemSettings(path: pane)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func openSystemSettings(path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func hasUsageDescription(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
