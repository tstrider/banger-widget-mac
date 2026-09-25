//  BangerContainer.swift — the one folder all three writers share.
//
//  It is ~/Library/Application Support/Banger, for every process, always — or
//  BANGER_CONTAINER, when a test or a tool points somewhere else on purpose.
//
//  WHY THERE IS NO CHOICE HERE. A sandboxed process without the matching app group
//  entitlement cannot open ~/Library/Group Containers, which is true for the widget and
//  the agent app. A process whose host app has wider file access can, so a resolver that
//  preferred the group container would let the CLI and the widget end up on two
//  different lists.
//
//  A CLI writing to one file while the widget reads another is the worst failure this
//  project has, so resolution does not depend on what the calling process happens to
//  be allowed to open. The widget can only ever reach Application Support — through the
//  home-relative temporary exception in BangerWidget.entitlements — so that is the
//  folder. A tasks.json in the app group location is never read; `bangerctl
//  path` reports it (`strayLists`) so a person can decide what to do with it.

import Foundation

public enum BangerContainer {

    /// An absolute directory path that wins over everything else. Used by the render
    /// harness and by anyone who needs a throwaway container.
    public static var overridePath: String? {
        guard let path = ProcessInfo.processInfo.environment["BANGER_CONTAINER"],
              !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    public struct Resolution: Sendable, Equatable {
        public enum Source: String, Sendable, Codable {
            /// BANGER_CONTAINER pointed us here.
            case override
            /// ~/Library/Application Support/Banger: the folder the widget can reach.
            /// The raw value is kept stable for `bangerctl path --json`, because agents
            /// check for it.
            case applicationSupport = "applicationSupportFallback"
        }

        public var url: URL
        public var source: Source
        /// Whether the folder existed before we resolved it.
        public var existedBeforeResolution: Bool
        /// Set only if the folder could not be created or opened. The store throws on use.
        public var creationErrorDescription: String?

        /// True for the shared folder. Means "not the app group"; kept because
        /// `bangerctl path --json` carries it.
        public var isFallback: Bool { source == .applicationSupport }
    }

    /// The user's real home, not the sandbox container. A sandboxed widget extension sees
    /// a redirected NSHomeDirectory(), so ask the password database instead.
    public static var realHomeDirectory: URL {
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var applicationSupportURL: URL {
        realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Banger", isDirectory: true)
    }

    /// The folder, as pure path arithmetic: no probing, nothing created. For readers that
    /// must not touch the disk to find it, like the day-boundary settings.
    public static var folderURL: URL {
        overridePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? applicationSupportURL
    }

    // MARK: - Resolution

    public static func resolve(fileManager: FileManager = .default) -> Resolution {
        let url = folderURL
        let existed = fileManager.fileExists(atPath: url.path)
        let problem = makeUsable(url, fileManager: fileManager)
        return Resolution(url: url,
                          source: overridePath == nil ? .applicationSupport : .override,
                          existedBeforeResolution: existed,
                          creationErrorDescription: problem)
    }

    /// Creates the directory if needed and proves we can actually see inside it.
    /// Returns a description of the problem, or nil when the folder is usable.
    private static func makeUsable(_ url: URL, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return "not a directory" }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return error.localizedDescription
            }
        }
        // Listing is the same permission gate as opening a file inside, and unlike a
        // probe file it leaves nothing behind.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: url.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Lists left somewhere else

    /// The legacy app group identifier, checked only for stray lists.
    static let legacyGroupIdentifier = "group.com.bangerwidget.banger"

    /// Any tasks.json sitting where an older build could have put one: the app group
    /// container, plain or team-prefixed. Nothing reads these. They are reported so that
    /// a list someone filled in the wrong place is found by a person, not by nobody.
    ///
    /// Only looks. A process that cannot open ~/Library/Group Containers — the widget,
    /// usually the agent — simply finds nothing.
    public static func strayLists(fileManager: FileManager = .default) -> [URL] {
        let root = realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
        var folders = [root.appendingPathComponent(legacyGroupIdentifier, isDirectory: true)]
        if let entries = try? fileManager.contentsOfDirectory(atPath: root.path) {
            folders += entries.filter { $0.hasSuffix("." + legacyGroupIdentifier) }
                .map { root.appendingPathComponent($0, isDirectory: true) }
        }
        let shared = folderURL.standardizedFileURL
        return folders
            .filter { $0.standardizedFileURL != shared }
            .map { $0.appendingPathComponent("tasks.json", isDirectory: false) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }
}
