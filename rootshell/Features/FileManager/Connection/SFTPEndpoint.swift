//
//  SFTPEndpoint.swift
//  rootshell
//
//  Where a file manager pane points: this device, a saved profile, or the
//  connection a terminal pane already holds.
//

import UIKit

enum SFTPEndpoint: Hashable {
    case local
    case profile(UUID)
    case pane(PaneSource)

    /// A terminal pane whose live connection can be borrowed. When the pane is
    /// gone, `fallbackProfileID` or `fallbackConfig` opens a dedicated connection.
    final class PaneSource: Hashable {
        let paneID: UUID
        let displayName: String
        weak var terminal: Ghostty.TerminalView?
        let fallbackProfileID: UUID?
        let fallbackConfig: ConnectionConfig
        /// Snapshot for "Open in Terminal", taken when the manager was opened from this pane.
        let openInFolderTarget: OpenInFolderTarget?

        init(terminal: Ghostty.TerminalView, openInFolderTarget: OpenInFolderTarget?) {
            let owner = TerminalConnectionOwner.resolve(for: terminal) ?? terminal
            paneID = owner.uuid
            displayName = owner.connectionConfig.displayName
            self.terminal = owner
            fallbackProfileID = owner.sourceProfileID
            fallbackConfig = owner.connectionConfig
            self.openInFolderTarget = openInFolderTarget
        }

        static func == (lhs: PaneSource, rhs: PaneSource) -> Bool { lhs.paneID == rhs.paneID }
        func hash(into hasher: inout Hasher) { hasher.combine(paneID) }
    }

    var isLocal: Bool {
        switch self {
        case .local: true
        case .pane(let source): source.fallbackConfig.underlyingSSHConfig == nil
        case .profile: false
        }
    }

    var displayName: String {
        switch self {
        case .local:
            return Self.localDeviceName
        case .profile(let id):
            return ConnectionProfileManager.shared.profile(for: id)?.name
                ?? String(localized: "Missing Profile", comment: "File manager: endpoint whose profile was deleted")
        case .pane(let source):
            return source.displayName
        }
    }

    private static var localDeviceName: String {
        #if targetEnvironment(macCatalyst)
        return String(localized: "This Mac", comment: "File manager: local endpoint name")
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
            ? String(localized: "This iPad", comment: "File manager: local endpoint name")
            : String(localized: "This iPhone", comment: "File manager: local endpoint name")
        #endif
    }

    /// The profile this endpoint connects through, if any.
    var profileID: UUID? {
        switch self {
        case .local: nil
        case .profile(let id): id
        case .pane(let source): source.fallbackProfileID
        }
    }

    /// Persistable form: panes are remembered by the profile they came from.
    var persistentKey: String? {
        switch self {
        case .local: "local"
        case .profile(let id): "profile:\(id.uuidString)"
        case .pane(let source): source.fallbackProfileID.map { "profile:\($0.uuidString)" }
        }
    }

    init?(persistentKey: String) {
        if persistentKey == "local" {
            self = .local
        } else if persistentKey.hasPrefix("profile:"),
                  let id = UUID(uuidString: String(persistentKey.dropFirst("profile:".count))),
                  ConnectionProfileManager.shared.profile(for: id) != nil {
            self = .profile(id)
        } else {
            return nil
        }
    }
}
