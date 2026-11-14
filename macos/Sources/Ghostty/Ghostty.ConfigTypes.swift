// This file contains the configuration types for Ghostty so that alternate targets
// can get typed information without depending on all the dependencies of GhosttyKit.

extension Ghostty {
    /// A configuration path value that may be optional or required.
    struct ConfigPath: Sendable {
        let path: String
        let optional: Bool
    }

    /// macos-icon
    enum MacOSIcon: String, Sendable {
        case official
        case blueprint
        case chalkboard
        case glass
        case holographic
        case microchip
        case paper
        case retro
        case xray
        case custom
        case customStyle = "custom-style"

    }

    /// macos-icon-frame
    enum MacOSIconFrame: String, Codable {
        case aluminum
        case beige
        case plastic
        case chrome
    }
}
