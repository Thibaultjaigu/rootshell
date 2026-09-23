//
//  FileTransferLogic.swift
//  rootshell
//
//  Pure transfer rules: destination mapping, conflict naming, rate and ETA.
//  No I/O, so it is unit-tested directly.
//

import Foundation

/// What to do when a transfer's destination already exists.
nonisolated enum TransferConflictResolution: String, CaseIterable, Sendable {
    case replace
    case skip
    case keepBoth
    /// Directories only: copy into the existing directory, replacing clashing files.
    case merge
}

nonisolated enum FileTransferLogic {
    /// POSIX join that tolerates trailing and leading slashes.
    static func join(_ base: String, _ component: String) -> String {
        if component.isEmpty { return base }
        let trimmedBase = base.hasSuffix("/") && base.count > 1 ? String(base.dropLast()) : base
        let trimmedComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return trimmedBase == "/" ? "/" + trimmedComponent : trimmedBase + "/" + trimmedComponent
    }

    static func lastComponent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func parent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// Maps `path` under `sourceRoot` to the same place under `destinationRoot`.
    static func destination(for path: String, sourceRoot: String, destinationRoot: String) -> String {
        guard path != sourceRoot else { return destinationRoot }
        let prefix = sourceRoot.hasSuffix("/") ? sourceRoot : sourceRoot + "/"
        guard path.hasPrefix(prefix) else { return join(destinationRoot, lastComponent(of: path)) }
        return join(destinationRoot, String(path.dropFirst(prefix.count)))
    }

    /// True when `candidate` is `directory` or lies beneath it, so copying
    /// `directory` into `candidate` would recurse into itself.
    static func isSameOrDescendant(_ candidate: String, of directory: String) -> Bool {
        candidate == directory || candidate.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// "name.ext" → "name 2.ext", skipping names in `existing`. Dotfiles keep their
    /// leading dot and multi-part extensions like ".tar.gz" stay attached.
    static func keepBothName(for name: String, existing: Set<String>) -> String {
        let (stem, suffix) = splitExtension(name)
        var index = 2
        while true {
            let candidate = "\(stem) \(index)\(suffix)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    static func splitExtension(_ name: String) -> (stem: String, suffix: String) {
        let body = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let lead = name.hasPrefix(".") ? "." : ""
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, !(parts.first?.isEmpty ?? true) else { return (name, "") }
        let compound = ["tar"]
        var extensionCount = 1
        if parts.count > 2, compound.contains(String(parts[parts.count - 2]).lowercased()) {
            extensionCount = 2
        }
        let stem = parts.dropLast(extensionCount).joined(separator: ".")
        let suffix = "." + parts.suffix(extensionCount).joined(separator: ".")
        return (lead + stem, suffix)
    }
}

/// Exponentially smoothed throughput from cumulative byte samples.
nonisolated struct TransferRateMeter: Sendable {
    /// Weight of the newest sample; lower is smoother.
    var smoothing = 0.3
    private(set) var bytesPerSecond: Double = 0
    private var lastBytes: Int64?
    private var lastTime: TimeInterval?

    mutating func record(totalBytes: Int64, at time: TimeInterval) {
        defer {
            lastBytes = totalBytes
            lastTime = time
        }
        guard let lastBytes, let lastTime, time > lastTime, totalBytes >= lastBytes else { return }
        let instant = Double(totalBytes - lastBytes) / (time - lastTime)
        bytesPerSecond = bytesPerSecond == 0 ? instant : smoothing * instant + (1 - smoothing) * bytesPerSecond
    }

    /// Seconds left for `remaining` bytes, nil until a rate is known.
    func eta(remainingBytes: Int64) -> TimeInterval? {
        guard bytesPerSecond > 0, remainingBytes >= 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}

/// Gates UI publication to a maximum rate.
nonisolated struct PublishThrottle: Sendable {
    let interval: TimeInterval
    private var last: TimeInterval = -.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldPublish(at time: TimeInterval, force: Bool = false) -> Bool {
        guard force || time - last >= interval else { return false }
        last = time
        return true
    }
}
