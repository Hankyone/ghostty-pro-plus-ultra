import Cocoa
import Combine

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
@MainActor
class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitDiffStats: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let needsAttention: Bool
        let tabColor: TerminalTabColor
        let faviconImage: NSImage?
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        /// Title with bell emoji stripped (the sidebar uses its own attention indicator).
        var displayTitle: String {
            title.hasPrefix("\u{1F514} ") ? String(title.dropFirst(3)) : title
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
        }
    }

    @Published var tabs: [TabItem] = []
    @Published var selectedTabID: ObjectIdentifier?

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    /// Cache of detected favicons keyed by pwd to avoid re-scanning every refresh.
    /// Static so all SidebarTabManager instances share it.
    private static var faviconCache: [String: NSImage?] = [:]

    /// Pwds currently being detected in the background, to avoid duplicate work.
    private static var faviconDetectionInFlight: Set<String> = []

    /// Cache for git diff stats to avoid spawning git every 0.5s.
    private var gitStatsCache: [String: String?] = [:]
    private var gitStatsCacheTime: Date = .distantPast
    private static let gitStatsCacheInterval: TimeInterval = 5.0

    /// Throttle for stale Claude PID sweeping (every 30s).
    private var lastPidSweepTime: Date = .distantPast
    private static let pidSweepInterval: TimeInterval = 30.0

    /// Fingerprint of the last timer-driven refresh, used to skip no-op rebuilds.
    private var lastRefreshFingerprint: Int = 0

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// Guard flag: when true, notification-driven refreshSelection() calls are
    /// suppressed so they don't overwrite the optimistic selectedTabID that
    /// selectTab() just set. The tabGroup.selectedWindow setter fires key-window
    /// notifications synchronously during assignment, and at that point the tab
    /// group's selectedWindow can return intermediate (old) state.
    private var isSelectingTab = false

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        setupObservers()
        refresh(reason: "init")
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let keyObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window,
                  let notifWindow = notification.object as? NSWindow,
                  (window.tabbedWindows ?? [window]).contains(notifWindow)
            else { return }
            self.refreshSelection()
        }
        observers.append(keyObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window,
                  let notifWindow = notification.object as? NSWindow,
                  (window.tabbedWindows ?? [window]).contains(notifWindow)
            else { return }
            self.refreshSelection()
        }
        observers.append(resignObserver)

        // Bell: respect bell-features config
        if bellTriggersAttention {
            let bellObserver = center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let w = controller.window else { return }
                let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
                if hasBell {
                    self.markAttention(window: w)
                } else {
                    self.clearAttention(for: ObjectIdentifier(w))
                    self.refresh(reason: "bell cleared")
                }
            }
            observers.append(bellObserver)
        }

        // Desktop notifications (OSC 9/99, command completion): always trigger attention
        let desktopNotifObserver = center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            self.markAttention(window: w)
        }
        observers.append(desktopNotifObserver)

        // IPC notifications (tab.notify command): trigger attention
        let ipcNotifObserver = center.addObserver(
            forName: .ghosttyIPCNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let w = notification.object as? NSWindow else { return }
            self.markAttention(window: w)
        }
        observers.append(ipcNotifObserver)

        // Poll periodically for tab group changes, title changes, pwd changes, metadata changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(reason: "timer")
        }
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        refresh(reason: "attention set")
    }

    private func clearAttention(for id: ObjectIdentifier) {
        guard attentionWindows.remove(id) != nil else { return }
        // Patch the cached tab model so the attention indicator clears immediately
        // without waiting for a full refresh().
        if let idx = tabs.firstIndex(where: { $0.id == id && $0.needsAttention }) {
            let old = tabs[idx]
            tabs[idx] = TabItem(
                id: old.id, title: old.title, pwd: old.pwd,
                gitDiffStats: old.gitDiffStats, surfaceId: old.surfaceId,
                statusEntries: old.statusEntries, needsAttention: false,
                tabColor: old.tabColor, faviconImage: old.faviconImage,
                window: old.window
            )
        }
    }

    // MARK: - Git Diff Stats

    /// Run `git diff --shortstat HEAD` and return a compact "+N -N" string,
    /// or nil if there are no uncommitted changes or the directory is not a git repo.
    private func gitDiffStats(at pwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--shortstat", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: pwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else { return nil }

        // Parse: " 3 files changed, 12 insertions(+), 5 deletions(-)"
        var insertions = 0
        var deletions = 0

        if let range = output.range(of: #"\d+ insertion"#, options: .regularExpression) {
            insertions = Int(output[range].split(separator: " ")[0]) ?? 0
        }
        if let range = output.range(of: #"\d+ deletion"#, options: .regularExpression) {
            deletions = Int(output[range].split(separator: " ")[0]) ?? 0
        }

        if insertions == 0 && deletions == 0 { return nil }
        return "+\(insertions) -\(deletions)"
    }

    // MARK: - Favicon Detection

    /// Search order for favicon files, based on common web framework conventions.
    private static let faviconSearchDirs = [
        "public",
        "app",
        "src/app",
        "src/assets",
        "assets",
        "static",
        "frontend/public",
        "",  // project root
    ]

    /// Extensions to try, in priority order (SVG > PNG > ICO > WEBP).
    private static let faviconExtensions = ["svg", "png", "ico", "webp"]

    /// Detect a favicon image for the project at the given pwd.
    /// Walks up to find a project root (package.json or .git), then searches
    /// known locations for favicon files. Results are cached by pwd.
    /// On cache miss, detection runs on a background queue and triggers a
    /// refresh when complete — returns nil immediately so the main thread
    /// is never blocked by filesystem scans.
    private func detectFavicon(at pwd: String) -> NSImage? {
        // Return cached result if available
        if let cached = Self.faviconCache[pwd] {
            return cached
        }

        // Start background detection if not already in progress
        if !Self.faviconDetectionInFlight.contains(pwd) {
            Self.faviconDetectionInFlight.insert(pwd)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let fm = FileManager.default
                let result = SidebarTabManager.findFaviconInBackground(at: pwd, using: fm)
                DispatchQueue.main.async {
                    Self.faviconDetectionInFlight.remove(pwd)
                    Self.faviconCache[pwd] = result
                    self?.refresh(reason: "favicon detected")
                }
            }
        }
        return nil
    }

    /// Fallback icon filenames when no favicon.* is found.
    private static let fallbackIconNames = [
        "icon-32x32.png", "icon-48x48.png", "icon-192x192.png",
        "apple-touch-icon.png", "logo.svg", "logo.png",
    ]

    /// Background-safe favicon search. Static so it can be called from a
    /// background queue without capturing `self`.
    nonisolated private static func findFaviconInBackground(at pwd: String, using fm: FileManager) -> NSImage? {
        var dir = pwd
        while dir != "/" && dir.hasPrefix("/Users") {
            let isProjectRoot = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("package.json"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Cargo.toml"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod"))

            if isProjectRoot {
                for searchDir in faviconSearchDirs {
                    let base = searchDir.isEmpty ? dir : (dir as NSString).appendingPathComponent(searchDir)
                    // Try standard favicon.{ext}
                    for ext in faviconExtensions {
                        let path = (base as NSString).appendingPathComponent("favicon.\(ext)")
                        if let image = loadFaviconFromDisk(at: path) { return image }
                    }
                    // Try sized variants and fallback names
                    let sized = (base as NSString).appendingPathComponent("favicon-32x32.png")
                    if let image = loadFaviconFromDisk(at: sized) { return image }

                    for name in fallbackIconNames {
                        let path = (base as NSString).appendingPathComponent(name)
                        if let image = loadFaviconFromDisk(at: path) { return image }
                    }
                }

                // Try app icons (iOS/macOS/Android)
                if let image = findAppIcon(in: dir, using: fm) { return image }

                // Try extracting favicon from HTML files
                if let image = extractFaviconFromHTML(in: dir, using: fm) { return image }

                return nil  // Found project root but no favicon
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    nonisolated private static func loadFaviconFromDisk(at path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 12, height: 12)
        return image
    }

    // MARK: - App Icon Detection (iOS/macOS/Android)

    /// xcassets directory names used by Xcode projects.
    private static let xcassetsNames = ["Assets.xcassets", "Images.xcassets"]

    /// App icon asset set directory names.
    private static let appIconSetNames = ["AppIcon.appiconset", "AppIconImage.imageset"]

    /// Known subdirectories where xcassets may live, relative to project root.
    private static let xcassetsSearchPaths = [
        "",              // project root (e.g. macOS apps like Ghostty)
        "ios/Runner",    // Flutter iOS
        "macos/Runner",  // Flutter macOS
        "ios",           // React Native (subdirs also checked)
        "macos",
    ]

    /// Android mipmap density directories in preferred order for small display.
    private static let androidMipmapDensities = [
        "mipmap-xhdpi", "mipmap-hdpi", "mipmap-xxhdpi",
        "mipmap-mdpi", "mipmap-xxxhdpi",
    ]

    /// Android res directory search paths.
    private static let androidResSearchPaths = [
        "app/src/main/res",
        "android/app/src/main/res",
    ]

    /// Minimal Decodable for Xcode asset catalog Contents.json.
    private struct AssetContents: Decodable {
        let images: [AssetImage]?
        struct AssetImage: Decodable {
            let filename: String?
            let size: String?
            let scale: String?
        }
    }

    /// Try iOS/macOS app icon first, then Android.
    nonisolated private static func findAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        if let image = findXcodeAppIcon(in: projectRoot, using: fm) { return image }
        if let image = findAndroidAppIcon(in: projectRoot, using: fm) { return image }
        return nil
    }

    /// Search for an Xcode app icon by looking for xcassets directories in
    /// known locations and the project root's immediate subdirectories.
    nonisolated private static func findXcodeAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        var dirsToCheck: [String] = []

        for searchPath in xcassetsSearchPaths {
            let base = searchPath.isEmpty ? projectRoot : (projectRoot as NSString).appendingPathComponent(searchPath)
            dirsToCheck.append(base)

            // For "ios"/"macos" paths, also check their immediate subdirectories
            // (React Native puts xcassets in ios/{ProjectName}/)
            if searchPath == "ios" || searchPath == "macos" {
                if let subdirs = try? fm.contentsOfDirectory(atPath: base) {
                    for subdir in subdirs where !subdir.hasPrefix(".") {
                        let fullPath = (base as NSString).appendingPathComponent(subdir)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                            dirsToCheck.append(fullPath)
                        }
                    }
                }
            }
        }

        // Also check immediate subdirectories of project root — native Xcode
        // projects often have source in a directory named after the project.
        if let rootContents = try? fm.contentsOfDirectory(atPath: projectRoot) {
            for item in rootContents where !item.hasPrefix(".") {
                let fullPath = (projectRoot as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    dirsToCheck.append(fullPath)
                }
            }
        }

        for dir in dirsToCheck {
            for xcassetsName in xcassetsNames {
                let xcassetsPath = (dir as NSString).appendingPathComponent(xcassetsName)
                guard fm.fileExists(atPath: xcassetsPath) else { continue }

                for iconSetName in appIconSetNames {
                    let iconSetPath = (xcassetsPath as NSString).appendingPathComponent(iconSetName)
                    guard fm.fileExists(atPath: iconSetPath) else { continue }

                    if let image = loadBestIconFromAssetSet(at: iconSetPath, using: fm) {
                        return image
                    }
                }
            }
        }
        return nil
    }

    /// Load the best-sized icon from an Xcode asset set by parsing Contents.json.
    /// Prefers icons around 60–120px to avoid loading the 1024px marketing icon.
    nonisolated private static func loadBestIconFromAssetSet(at path: String, using fm: FileManager) -> NSImage? {
        let contentsPath = (path as NSString).appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: contentsPath)),
              let contents = try? JSONDecoder().decode(AssetContents.self, from: data),
              let images = contents.images else {
            // No Contents.json — try loading any image file directly
            return loadAnyImageFromDirectory(at: path, using: fm)
        }

        let candidates: [(String, Int)] = images.compactMap { img in
            guard let filename = img.filename else { return nil }
            let filePath = (path as NSString).appendingPathComponent(filename)
            guard fm.fileExists(atPath: filePath) else { return nil }
            let pixelSize = pixelSizeFromAsset(size: img.size, scale: img.scale)
            return (filePath, pixelSize)
        }

        // Sort by closeness to 90px — a good middle ground for downscaling to 12px
        let sorted = candidates.sorted { abs($0.1 - 90) < abs($1.1 - 90) }
        for (filePath, _) in sorted {
            if let image = loadFaviconFromDisk(at: filePath) { return image }
        }

        return nil
    }

    /// Calculate pixel size from Contents.json size/scale strings.
    nonisolated private static func pixelSizeFromAsset(size: String?, scale: String?) -> Int {
        guard let size = size,
              let pointSize = Double(size.split(separator: "x").first ?? "") else { return 0 }
        let scaleVal = Double(scale?.replacingOccurrences(of: "x", with: "") ?? "1") ?? 1.0
        return Int(pointSize * scaleVal)
    }

    /// Fallback: load any image file from a directory.
    nonisolated private static func loadAnyImageFromDirectory(at path: String, using fm: FileManager) -> NSImage? {
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        for filename in contents {
            let ext = (filename as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                let filePath = (path as NSString).appendingPathComponent(filename)
                if let image = loadFaviconFromDisk(at: filePath) { return image }
            }
        }
        return nil
    }

    /// Search Android mipmap directories for launcher icons.
    nonisolated private static func findAndroidAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        let iconNames = ["ic_launcher.png", "ic_launcher.webp",
                         "ic_launcher_round.png", "ic_launcher_round.webp"]

        for resPath in androidResSearchPaths {
            let resDir = (projectRoot as NSString).appendingPathComponent(resPath)
            guard fm.fileExists(atPath: resDir) else { continue }

            for density in androidMipmapDensities {
                let mipmapDir = (resDir as NSString).appendingPathComponent(density)
                for iconName in iconNames {
                    let iconPath = (mipmapDir as NSString).appendingPathComponent(iconName)
                    if let image = loadFaviconFromDisk(at: iconPath) { return image }
                }
            }
        }
        return nil
    }

    // MARK: - HTML Favicon Extraction

    /// HTML files to check for embedded favicon references, in priority order.
    private static let htmlFileNames = ["index.html", "index.htm"]

    /// Search HTML files for `<link rel="icon" href="...">` and resolve the
    /// href — either as a file path relative to the project root, or as an
    /// inline data URI (SVG or base64-encoded image).
    nonisolated private static func extractFaviconFromHTML(in projectRoot: String, using fm: FileManager) -> NSImage? {
        for name in htmlFileNames {
            // Look for the HTML file in the same dirs we search for favicon files
            for searchDir in faviconSearchDirs {
                let base = searchDir.isEmpty ? projectRoot : (projectRoot as NSString).appendingPathComponent(searchDir)
                let htmlPath = (base as NSString).appendingPathComponent(name)
                guard fm.fileExists(atPath: htmlPath),
                      let contents = try? String(contentsOfFile: htmlPath, encoding: .utf8) else { continue }

                if let image = parseFaviconFromHTML(contents, projectRoot: projectRoot, htmlDir: base, using: fm) {
                    return image
                }
            }
        }
        return nil
    }

    /// Parse HTML content for a `<link>` tag with rel containing "icon" and
    /// extract the href value.
    nonisolated private static func parseFaviconFromHTML(_ html: String, projectRoot: String, htmlDir: String, using fm: FileManager) -> NSImage? {
        // Match <link> tags that may contain quoted attributes with > or mixed
        // quotes inside (common with inline SVG data URIs). The alternation
        // handles: bare chars, double-quoted strings, and single-quoted strings.
        let tagPattern = #"<link\s(?:[^>"']|"[^"]*"|'[^']*')*>"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) else { return nil }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let tagMatches = tagRegex.matches(in: html, range: range)

        for tagMatch in tagMatches {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let tag = String(html[tagRange])

            // Only consider tags where rel includes "icon"
            let relPattern = #"rel\s*=\s*["'](?:shortcut\s+)?icon["']"#
            guard let relRegex = try? NSRegularExpression(pattern: relPattern, options: .caseInsensitive),
                  relRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) != nil else { continue }

            // Extract href — try double-quoted then single-quoted to respect
            // the actual delimiter (data URIs often contain the other quote type).
            let href: String?
            if let val = extractAttributeValue(from: tag, attribute: "href", quote: "\"") {
                href = val
            } else if let val = extractAttributeValue(from: tag, attribute: "href", quote: "'") {
                href = val
            } else {
                continue
            }
            guard let href else { continue }

            // Handle data URIs
            if href.hasPrefix("data:") {
                if let image = loadFaviconFromDataURI(href) { return image }
                continue
            }

            // Handle file path references — resolve relative to project root
            let resolvedPath: String
            if href.hasPrefix("/") {
                // Absolute path from project root
                resolvedPath = (projectRoot as NSString).appendingPathComponent(String(href.dropFirst()))
            } else {
                // Relative to the HTML file's directory
                resolvedPath = (htmlDir as NSString).appendingPathComponent(href)
            }
            if let image = loadFaviconFromDisk(at: resolvedPath) { return image }
        }
        return nil
    }

    /// Extract an attribute value from an HTML tag using the specified quote
    /// delimiter. This avoids regex issues with data URIs that contain mixed
    /// quote types and angle brackets.
    nonisolated private static func extractAttributeValue(from tag: String, attribute: String, quote: Character) -> String? {
        // Find the attribute name followed by = and the opening quote
        let search = "\(attribute)="
        guard let attrStart = tag.range(of: search, options: .caseInsensitive) else { return nil }
        let afterEquals = tag[attrStart.upperBound...]
        // Skip optional whitespace
        let trimmed = afterEquals.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == quote else { return nil }
        let valueStart = trimmed.index(after: trimmed.startIndex)
        guard let valueEnd = trimmed[valueStart...].firstIndex(of: quote) else { return nil }
        return String(trimmed[valueStart..<valueEnd])
    }

    /// Decode a `data:` URI into an NSImage. Supports:
    /// - `data:image/svg+xml,...` (URL-encoded SVG)
    /// - `data:image/svg+xml;base64,...`
    /// - `data:image/png;base64,...` (and other image types)
    nonisolated private static func loadFaviconFromDataURI(_ uri: String) -> NSImage? {
        // Split into metadata and payload at the first comma
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let metadata = String(uri[uri.startIndex..<commaIndex]).lowercased()
        let payload = String(uri[uri.index(after: commaIndex)...])

        guard metadata.hasPrefix("data:image/") else { return nil }

        let imageData: Data?
        if metadata.contains(";base64") {
            imageData = Data(base64Encoded: payload)
        } else {
            // URL-encoded content (common for inline SVG)
            guard let decoded = payload.removingPercentEncoding else { return nil }
            imageData = decoded.data(using: .utf8)
        }

        guard let data = imageData, let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 12, height: 12)
        return image
    }

    // MARK: - Selection

    /// Lightweight update that only syncs `selectedTabID` from the window's tab group,
    /// without rebuilding the full tab list.
    private func refreshSelection() {
        guard !isSelectingTab else { return }
        guard let window else { return }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let newID = ObjectIdentifier(selectedWindow)
        if selectedTabID != newID {
            selectedTabID = newID
        }
    }

    // MARK: - Refresh

    func refresh() {
        refresh(reason: "manual")
    }

    private func refresh(reason: String) {
        guard let window else { return }

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        // For timer-driven refreshes, skip if nothing observable has changed.
        if reason == "timer" {
            var hasher = Hasher()
            hasher.combine(tabWindows.count)
            hasher.combine(ObjectIdentifier(selectedWindow))
            hasher.combine(attentionWindows.count)
            for w in tabWindows {
                hasher.combine(ObjectIdentifier(w))
                hasher.combine(w.title)
                if let ctrl = w.windowController as? BaseTerminalController,
                   let surface = ctrl.focusedSurface {
                    hasher.combine(surface.pwd)
                    hasher.combine(surface.id)
                    for entry in metadataStore.statusEntries(for: surface.id) {
                        hasher.combine(entry.key)
                        hasher.combine(entry.value)
                        hasher.combine(entry.icon)
                    }
                }
            }
            let fingerprint = hasher.finalize()
            if fingerprint == lastRefreshFingerprint {
                return
            }
            lastRefreshFingerprint = fingerprint
        }

        // Collect pwds for background git refresh
        var tabPwds: [String] = []
        var faviconCacheMisses = 0

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            // Always use cached git stats (never block the main thread)
            let diffStats = pwd.flatMap { gitStatsCache[$0] ?? nil }
            let favicon = pwd.flatMap { pwd -> NSImage? in
                if Self.faviconCache.index(forKey: pwd) == nil {
                    faviconCacheMisses += 1
                }
                return detectFavicon(at: pwd)
            }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            if let p = pwd { tabPwds.append(p) }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitDiffStats: diffStats,
                surfaceId: sid,
                statusEntries: entries,
                needsAttention: attentionWindows.contains(wid),
                tabColor: color,
                faviconImage: favicon,
                window: w
            )
        }

        // Sweep stale Claude sessions (every 30s) — detects crashed Claude processes
        if Date().timeIntervalSince(lastPidSweepTime) >= Self.pidSweepInterval {
            lastPidSweepTime = Date()
            metadataStore.sweepStaleClaude()
        }

        // Refresh git stats in the background periodically
        let isWindowActive = window.isKeyWindow || NSApp.isActive
        let shouldRefreshGitStats = isWindowActive && Date().timeIntervalSince(gitStatsCacheTime) >= Self.gitStatsCacheInterval
        if shouldRefreshGitStats {
            gitStatsCacheTime = Date()
            let pwds = tabPwds
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var newStats: [String: String?] = [:]
                for pwd in pwds {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["diff", "--shortstat", "HEAD"]
                    process.currentDirectoryURL = URL(fileURLWithPath: pwd)
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = Pipe()
                    guard (try? process.run()) != nil else { newStats[pwd] = nil; continue }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { newStats[pwd] = nil; continue }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !output.isEmpty else { newStats[pwd] = nil; continue }
                    var ins = 0, del = 0
                    if let r = output.range(of: #"\d+ insertion"#, options: .regularExpression) {
                        ins = Int(output[r].split(separator: " ")[0]) ?? 0
                    }
                    if let r = output.range(of: #"\d+ deletion"#, options: .regularExpression) {
                        del = Int(output[r].split(separator: " ")[0]) ?? 0
                    }
                    newStats[pwd] = (ins == 0 && del == 0) ? nil : "+\(ins) -\(del)"
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Clear all checked pwds first — assigning nil to a
                    // [String: String?] dict removes the key rather than
                    // storing nil, so stale entries would never be cleared.
                    for pwd in pwds {
                        self.gitStatsCache.removeValue(forKey: pwd)
                    }
                    for (pwd, stats) in newStats {
                        self.gitStatsCache[pwd] = stats
                    }
                    self.refresh(reason: "git stats completed")
                }
            }
        }

        let tabsChanged = newTabs != tabs
        if tabsChanged {
            tabs = newTabs
        }

        let currentSelectedID = ObjectIdentifier(selectedWindow)
        if selectedTabID != currentSelectedID {
            selectedTabID = currentSelectedID
        }
    }

    // MARK: - Tab Actions

    func createNewTab() {
        NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
    }

    func selectTab(_ tab: TabItem) {
        // Only remove from the set — don't patch the @Published tabs array.
        // The source sidebar is about to become invisible anyway, and the next
        // timer-driven refresh() will rebuild tabs with needsAttention=false.
        attentionWindows.remove(tab.id)
        selectedTabID = tab.id
        // Guard against notification-driven refreshSelection() calls that fire
        // synchronously during the tabGroup.selectedWindow setter. Without this,
        // those handlers read intermediate state and revert our optimistic update.
        isSelectingTab = true
        if let window,
           let tabGroup = window.tabGroup,
           tabGroup.windows.contains(tab.window) {
            tabGroup.selectedWindow = tab.window
        } else {
            tab.window.makeKeyAndOrderFront(nil)
        }
        isSelectingTab = false

        // After the setter, the target window's sidebar is now visible to the user.
        // Its manager's refreshSelection may have run during the setter and read
        // intermediate (old) state. Correct it now that the setter has completed.
        if let targetController = tab.window.windowController as? TerminalController,
           let targetManager = targetController.sidebarTabManager,
           targetManager !== self {
            targetManager.selectedTabID = tab.id
        }
    }

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (tab.window as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard let window else { return }
        guard let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        if sourceIndex > destinationIndex {
            targetWindow.addTabbedWindow(movingWindow, ordered: .below)
        } else {
            targetWindow.addTabbedWindow(movingWindow, ordered: .above)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        for w in tabWindows[(idx + 1)...] {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
