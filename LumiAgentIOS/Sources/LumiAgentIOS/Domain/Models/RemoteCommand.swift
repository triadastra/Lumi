//
//  RemoteCommand.swift
//  LumiAgentIOS
//
//  Shared wire protocol for iOS ↔ macOS remote control.
//  Both sides encode/decode these types over the Bonjour TCP connection.
//

import Foundation

// MARK: - Command

/// A command sent from the iOS app to a macOS LumiAgent instance.
public struct RemoteCommand: Codable, Identifiable, Sendable {
    public let id: UUID
    public let commandType: CommandType
    public let parameters: [String: String]

    public init(
        commandType: CommandType,
        parameters: [String: String] = [:]
    ) {
        self.id = UUID()
        self.commandType = commandType
        self.parameters = parameters
    }

    // MARK: - Command Types

    public enum CommandType: String, Codable, CaseIterable, Sendable {
        // System display
        case setBrightness      = "set_brightness"
        case getBrightness      = "get_brightness"

        // System audio
        case setVolume          = "set_volume"
        case getVolume          = "get_volume"
        case setMute            = "set_mute"
        case getMute            = "get_mute"
        case listAudioDevices   = "list_audio_devices"
        case setAudioOutput     = "set_audio_output"

        // Media playback
        case mediaPlay          = "media_play"
        case mediaPause         = "media_pause"
        case mediaToggle        = "media_toggle"
        case mediaNext          = "media_next"
        case mediaPrevious      = "media_previous"
        case mediaGetInfo       = "media_get_info"
        case mediaStop          = "media_stop"

        // Screen interaction
        case screenshot         = "screenshot"
        case getScreenInfo      = "get_screen_info"
        case moveMouse          = "move_mouse"
        case clickMouse         = "click_mouse"
        case scrollMouse        = "scroll_mouse"

        // Text / keyboard
        case typeText           = "type_text"
        case pressKey           = "press_key"

        // App management
        case openApplication    = "open_application"
        case launchURL          = "launch_url"
        case listRunningApps    = "list_running_apps"
        case quitApplication    = "quit_application"

        // Automation
        case runAppleScript     = "run_applescript"
        case runShellCommand    = "run_shell_command"

        // System info
        case getSystemInfo      = "get_system_info"
        case getBatteryInfo     = "get_battery_info"
        case getNetworkInfo     = "get_network_info"

        // Notifications
        case sendNotification   = "send_notification"

        // Connection
        case ping               = "ping"
        case disconnect         = "disconnect"

        // Data Sync
        case getSyncData        = "get_sync_data"
        case pushSyncData       = "push_sync_data"

        var displayName: String {
            switch self {
            case .setBrightness:    return "Set Brightness"
            case .getBrightness:    return "Get Brightness"
            case .setVolume:        return "Set Volume"
            case .getVolume:        return "Get Volume"
            case .setMute:          return "Set Mute"
            case .getMute:          return "Get Mute"
            case .listAudioDevices: return "List Audio Devices"
            case .setAudioOutput:   return "Set Audio Output"
            case .mediaPlay:        return "Play"
            case .mediaPause:       return "Pause"
            case .mediaToggle:      return "Play/Pause"
            case .mediaNext:        return "Next Track"
            case .mediaPrevious:    return "Previous Track"
            case .mediaGetInfo:     return "Now Playing Info"
            case .mediaStop:        return "Stop"
            case .screenshot:       return "Take Screenshot"
            case .getScreenInfo:    return "Screen Info"
            case .moveMouse:        return "Move Mouse"
            case .clickMouse:       return "Click"
            case .scrollMouse:      return "Scroll"
            case .typeText:         return "Type Text"
            case .pressKey:         return "Press Key"
            case .openApplication:  return "Open App"
            case .launchURL:        return "Open URL"
            case .listRunningApps:  return "Running Apps"
            case .quitApplication:  return "Quit App"
            case .runAppleScript:   return "Run AppleScript"
            case .runShellCommand:  return "Shell Command"
            case .getSystemInfo:    return "System Info"
            case .getBatteryInfo:   return "Battery Info"
            case .getNetworkInfo:   return "Network Info"
            case .sendNotification: return "Send Notification"
            case .ping:             return "Ping"
            case .disconnect:       return "Disconnect"
            case .getSyncData:      return "Sync (Pull)"
            case .pushSyncData:     return "Sync (Push)"
            }
        }

        var systemImage: String {
            switch self {
            case .setBrightness, .getBrightness:    return "sun.max.fill"
            case .setVolume, .getVolume:            return "speaker.wave.2.fill"
            case .setMute, .getMute:                return "speaker.slash.fill"
            case .listAudioDevices, .setAudioOutput: return "airplayaudio"
            case .mediaPlay:                        return "play.fill"
            case .mediaPause:                       return "pause.fill"
            case .mediaToggle:                      return "playpause.fill"
            case .mediaNext:                        return "forward.fill"
            case .mediaPrevious:                    return "backward.fill"
            case .mediaGetInfo:                     return "music.note"
            case .mediaStop:                        return "stop.fill"
            case .screenshot:                       return "camera.viewfinder"
            case .getScreenInfo:                    return "display"
            case .moveMouse, .clickMouse:           return "cursorarrow.click"
            case .scrollMouse:                      return "scroll"
            case .typeText:                         return "keyboard"
            case .pressKey:                         return "command"
            case .openApplication:                  return "app.badge"
            case .launchURL:                        return "safari"
            case .listRunningApps, .quitApplication: return "apps.iphone"
            case .runAppleScript:                   return "applescript"
            case .runShellCommand:                  return "terminal"
            case .getSystemInfo:                    return "info.circle"
            case .getBatteryInfo:                   return "battery.100"
            case .getNetworkInfo:                   return "network"
            case .sendNotification:                 return "bell.fill"
            case .ping:                             return "antenna.radiowaves.left.and.right"
            case .disconnect:                       return "xmark.circle"
            case .getSyncData:                      return "icloud.and.arrow.down"
            case .pushSyncData:                     return "icloud.and.arrow.up"
            }
        }
    }
}

// MARK: - Response

/// Response returned from macOS LumiAgent after executing a command.
public struct RemoteCommandResponse: Codable, Sendable {
    public let id: UUID
    public let success: Bool
    public let result: String
    public let error: String?
    /// Base64-encoded JPEG for screenshot commands.
    public let imageData: String?

    public init(
        id: UUID,
        success: Bool,
        result: String,
        error: String? = nil,
        imageData: String? = nil
    ) {
        self.id = id
        self.success = success
        self.result = result
        self.error = error
        self.imageData = imageData
    }

    public static func failure(id: UUID, error: String) -> RemoteCommandResponse {
        RemoteCommandResponse(id: id, success: false, result: "", error: error)
    }
}

// MARK: - Wire Frame

/// Framed JSON message over the TCP connection.
/// Wire format: 4-byte big-endian length prefix + UTF-8 JSON payload.
public enum WireFrame {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
