import Cocoa

/// Background-safe project icon discovery for the sidebar.
///
/// Given a working directory, walks up to the project root and searches web
/// favicon conventions, Xcode/Android app icon catalogs, Chrome extension /
/// PWA manifests, and HTML `<link rel="icon">` references. All functions are
/// nonisolated and safe to call from a background queue.
enum SidebarFaviconFinder {

    /// Search order for favicon files, based on common web framework conventions.
    private static let faviconSearchDirs = [
        "public",
        "app",
        "src/app",
        "src/assets",
        "assets",
        "static",
        "frontend/public",
        "icons",  // Chrome extension / PWA icon directory
        "",  // project root
    ]

    /// Extensions to try, in priority order (SVG > PNG > ICO > WEBP).
    private static let faviconExtensions = ["svg", "png", "ico", "webp"]

    /// Fallback icon filenames when no favicon.* is found.
    private static let fallbackIconNames = [
        "icon-32x32.png", "icon-48x48.png", "icon-192x192.png",
        "apple-touch-icon.png", "logo.svg", "logo.png",
        // Chrome extension / PWA icon naming conventions
        "icon16.png", "icon32.png", "icon48.png", "icon128.png",
    ]

    /// Find a favicon for the project containing `pwd`, or nil.
    static func find(at pwd: String) -> NSImage? {
        let fm = FileManager.default
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
                        if let image = loadFromDisk(at: path) { return image }
                    }
                    // Try sized variants and fallback names
                    let sized = (base as NSString).appendingPathComponent("favicon-32x32.png")
                    if let image = loadFromDisk(at: sized) { return image }

                    for name in fallbackIconNames {
                        let path = (base as NSString).appendingPathComponent(name)
                        if let image = loadFromDisk(at: path) { return image }
                    }
                }

                // Try app icons (iOS/macOS/Android)
                if let image = findAppIcon(in: dir, using: fm) { return image }

                // Try Chrome extension / PWA manifest.json icons
                if let image = findChromeExtensionIcon(in: dir, using: fm) { return image }

                // Try extracting favicon from HTML files
                if let image = extractFaviconFromHTML(in: dir, using: fm) { return image }

                return nil  // Found project root but no favicon
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func loadFromDisk(at path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
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
    private static func findAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        if let image = findXcodeAppIcon(in: projectRoot, using: fm) { return image }
        if let image = findAndroidAppIcon(in: projectRoot, using: fm) { return image }
        return nil
    }

    /// Search for an Xcode app icon by looking for xcassets directories in
    /// known locations and the project root's immediate subdirectories.
    private static func findXcodeAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
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
    private static func loadBestIconFromAssetSet(at path: String, using fm: FileManager) -> NSImage? {
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
            if let image = loadFromDisk(at: filePath) { return image }
        }

        return nil
    }

    /// Calculate pixel size from Contents.json size/scale strings.
    private static func pixelSizeFromAsset(size: String?, scale: String?) -> Int {
        guard let size = size,
              let pointSize = Double(size.split(separator: "x").first ?? "") else { return 0 }
        let scaleVal = Double(scale?.replacingOccurrences(of: "x", with: "") ?? "1") ?? 1.0
        return Int(pointSize * scaleVal)
    }

    /// Fallback: load any image file from a directory.
    private static func loadAnyImageFromDirectory(at path: String, using fm: FileManager) -> NSImage? {
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        for filename in contents {
            let ext = (filename as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                let filePath = (path as NSString).appendingPathComponent(filename)
                if let image = loadFromDisk(at: filePath) { return image }
            }
        }
        return nil
    }

    /// Search Android mipmap directories for launcher icons.
    private static func findAndroidAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        let iconNames = ["ic_launcher.png", "ic_launcher.webp",
                         "ic_launcher_round.png", "ic_launcher_round.webp"]

        for resPath in androidResSearchPaths {
            let resDir = (projectRoot as NSString).appendingPathComponent(resPath)
            guard fm.fileExists(atPath: resDir) else { continue }

            for density in androidMipmapDensities {
                let mipmapDir = (resDir as NSString).appendingPathComponent(density)
                for iconName in iconNames {
                    let iconPath = (mipmapDir as NSString).appendingPathComponent(iconName)
                    if let image = loadFromDisk(at: iconPath) { return image }
                }
            }
        }
        return nil
    }

    // MARK: - Chrome Extension / PWA Manifest Icon Extraction

    /// Minimal Decodable for Chrome extension / PWA manifest.json.
    /// Both `icons` and `action.default_icon` map size strings to file paths.
    private struct WebManifest: Decodable {
        let icons: [String: String]?
        let action: Action?
        struct Action: Decodable {
            let defaultIcon: [String: String]?
            enum CodingKeys: String, CodingKey {
                case defaultIcon = "default_icon"
            }
        }
    }

    /// Parse manifest.json (Chrome extension MV3 or PWA Web App Manifest)
    /// and load the best-sized icon. Prefers the top-level `icons` field,
    /// falls back to `action.default_icon` (the toolbar button icon).
    private static func findChromeExtensionIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        let manifestPath = (projectRoot as NSString).appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let manifest = try? JSONDecoder().decode(WebManifest.self, from: data) else {
            return nil
        }

        // Prefer top-level icons, then action.default_icon
        let iconMap = manifest.icons ?? manifest.action?.defaultIcon
        guard let iconMap, !iconMap.isEmpty else { return nil }

        // Pick the size closest to 48px — good middle ground for downscaling to 16px
        let sorted = iconMap.sorted { lhs, rhs in
            let lhsSize = Int(lhs.key) ?? 0
            let rhsSize = Int(rhs.key) ?? 0
            return abs(lhsSize - 48) < abs(rhsSize - 48)
        }

        for (_, relPath) in sorted {
            let iconPath = (projectRoot as NSString).appendingPathComponent(relPath)
            if let image = loadFromDisk(at: iconPath) { return image }
        }
        return nil
    }

    // MARK: - HTML Favicon Extraction

    /// HTML files to check for embedded favicon references, in priority order.
    private static let htmlFileNames = ["index.html", "index.htm"]

    /// Search HTML files for `<link rel="icon" href="...">` and resolve the
    /// href — either as a file path relative to the project root, or as an
    /// inline data URI (SVG or base64-encoded image).
    private static func extractFaviconFromHTML(in projectRoot: String, using fm: FileManager) -> NSImage? {
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
    private static func parseFaviconFromHTML(_ html: String, projectRoot: String, htmlDir: String, using fm: FileManager) -> NSImage? {
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
                if let image = loadFromDataURI(href) { return image }
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
            if let image = loadFromDisk(at: resolvedPath) { return image }
        }
        return nil
    }

    /// Extract an attribute value from an HTML tag using the specified quote
    /// delimiter. This avoids regex issues with data URIs that contain mixed
    /// quote types and angle brackets.
    private static func extractAttributeValue(from tag: String, attribute: String, quote: Character) -> String? {
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
    private static func loadFromDataURI(_ uri: String) -> NSImage? {
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
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
