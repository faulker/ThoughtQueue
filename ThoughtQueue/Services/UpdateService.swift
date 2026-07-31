import Cocoa
import CryptoKit
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "UpdateService")

/// Checks GitHub Releases for a newer ThoughtQueue and installs it in place.
///
/// Deliberately avoids the GitHub API: the check is a `HEAD` against the public
/// `/releases/latest` URL, which 302-redirects to `/releases/tag/vX.Y.Z`. That needs no auth
/// and is not rate limited. Downloads are verified against the release's
/// `checksums-sha256.txt` asset before anything touches the installed app bundle.
final class UpdateService {
    static let shared = UpdateService()

    /// Owner/repo the releases are published under.
    static let repoSlug = "faulker/ThoughtQueue"

    /// How often the automatic check can run. Index into this array is what the Preferences
    /// popup stores, so it is the single source of truth for both titles and hour values.
    static let intervalChoices: [(title: String, hours: Int)] = [
        ("Every hour", 1),
        ("Every 6 hours", 6),
        ("Daily", 24),
        ("Weekly", 168),
    ]

    /// A release newer than what's running.
    struct Release {
        let version: String
        var tag: String { "v\(version)" }
        var pageURL: URL { UpdateService.releasePageURL(version: version) }
        var zipURL: URL { UpdateService.assetURL(version: version, filename: "ThoughtQueue-\(version).zip") }
        var checksumsURL: URL { UpdateService.assetURL(version: version, filename: "checksums-sha256.txt") }
    }

    enum UpdateError: LocalizedError, Equatable {
        case alreadyChecking
        case localDevelopmentBuild
        case badResponse
        case unreadableVersion
        case checksumMissing(String)
        case checksumMismatch(expected: String, got: String)
        case unzipFailed(String)
        case bundleMissing
        case bundleMismatch(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .alreadyChecking:
                return "A check is already in progress."
            case .localDevelopmentBuild:
                return "Local development build — updates are only offered for installed releases."
            case .badResponse:
                return "GitHub did not return a usable response."
            case .unreadableVersion:
                return "Could not read the latest version number from GitHub."
            case .checksumMissing(let name):
                return "The release has no published checksum for \(name)."
            case .checksumMismatch(let expected, let got):
                return "The download did not match its published checksum.\nExpected \(expected)\nGot \(got)"
            case .unzipFailed(let msg):
                return "Could not unpack the download: \(msg)"
            case .bundleMissing:
                return "The download did not contain ThoughtQueue.app."
            case .bundleMismatch(let detail):
                return "The downloaded app failed validation: \(detail)"
            case .notWritable(let path):
                return "ThoughtQueue can't update itself because \(path) is not writable."
            }
        }
    }

    private var timer: Timer?
    private var isChecking = false
    /// Version already offered and postponed during this run, so the automatic check does not
    /// nag repeatedly. User-initiated checks ignore this.
    private var lastPromptedVersion: String?

    private init() {}

    // MARK: - URLs

    static var latestReleaseURL: URL {
        URL(string: "https://github.com/\(repoSlug)/releases/latest")!
    }

    static func releasePageURL(version: String) -> URL {
        URL(string: "https://github.com/\(repoSlug)/releases/tag/v\(version)")!
    }

    static func assetURL(version: String, filename: String) -> URL {
        URL(string: "https://github.com/\(repoSlug)/releases/download/v\(version)/\(filename)")!
    }

    // MARK: - Pure helpers (testable without touching the network)

    /// The running app's marketing version, e.g. "1.0.0".
    static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// True when this process is an Xcode / `build.sh` product, not a downloaded or
    /// Applications-installed copy. Those live under `DerivedData` or `Build/Products`.
    static func isLocalDevelopmentBuild(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    /// Pulls "1.2.3" out of a `.../releases/tag/v1.2.3` URL. Returns nil if the last path
    /// component isn't version-shaped, which is how a redirect to the releases index (no
    /// releases published yet) gets rejected.
    static func parseVersion(fromTagURL url: URL) -> String? {
        var component = url.lastPathComponent
        if component.hasPrefix("v") || component.hasPrefix("V") {
            component.removeFirst()
        }
        guard let first = component.split(separator: ".").first,
              !first.isEmpty,
              first.allSatisfy(\.isNumber) else { return nil }
        return component
    }

    /// Compares dotted version strings numerically, so 1.10.0 sorts above 1.9.0. Missing
    /// components count as zero (2.0 == 2.0.0) and any `-prerelease` / `+build` suffix is
    /// dropped before comparing.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func numericComponents(_ version: String) -> [Int] {
        let core = version.prefix { $0 != "-" && $0 != "+" }
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Looks up a filename in a `shasum -a 256` output block. The release workflow runs shasum
    /// from inside `dist/`, so the listed paths carry a `./` prefix. Everything after the hash
    /// is treated as the name, so a filename containing spaces still matches.
    static func expectedSHA256(for filename: String, in checksums: String) -> String? {
        for line in checksums.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = String(trimmed[trimmed.startIndex..<separator])
            // The second field may be prefixed with "*" (binary mode) as well as "./".
            var name = String(trimmed[separator...]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if name == filename, !hash.isEmpty {
                return hash.lowercased()
            }
        }
        return nil
    }

    /// Wraps a path for safe interpolation into a single-quoted shell string, so a home
    /// directory like /Users/o'brien can't break out of the quoting in the swap script.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Scheduling

    /// (Re)arms the periodic check from the current preferences. Safe to call repeatedly;
    /// invalidates any existing timer first.
    func startScheduler() {
        timer?.invalidate()
        timer = nil

        NotificationCenter.default.removeObserver(self, name: .updateCheckSettingsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .updateCheckSettingsDidChange, object: nil
        )
        // Timers don't fire while the Mac is asleep, so a laptop that sleeps overnight would
        // otherwise skip its daily check entirely.
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        guard !Self.isLocalDevelopmentBuild() else {
            log.info("Skipping update scheduler for local development build")
            return
        }

        guard PreferencesManager.shared.autoUpdateCheckEnabled else {
            log.info("Automatic update checks are disabled")
            return
        }

        let interval = TimeInterval(PreferencesManager.shared.updateCheckIntervalHours) * 3600
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.check(userInitiated: false)
        }
        t.tolerance = interval * 0.1
        timer = t
        log.info("Scheduled update checks every \(Int(interval / 3600)) h")
    }

    func stopScheduler() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func settingsChanged() {
        startScheduler()
    }

    @objc private func systemDidWake() {
        guard !Self.isLocalDevelopmentBuild() else { return }
        guard PreferencesManager.shared.autoUpdateCheckEnabled else { return }
        let interval = TimeInterval(PreferencesManager.shared.updateCheckIntervalHours) * 3600
        guard let last = PreferencesManager.shared.lastUpdateCheckAt else {
            check(userInitiated: false)
            return
        }
        if Date().timeIntervalSince(last) >= interval {
            check(userInitiated: false)
        }
    }

    // MARK: - Checking

    /// Asks GitHub for the latest published release. `completion` runs on the main thread with
    /// the newer release, or nil when already up to date. Automatic checks prompt at most once
    /// per version per app run; user-initiated checks always report back.
    ///
    /// Local development builds (Xcode / `build.sh` products) never check or prompt: an
    /// in-place update would overwrite the build product, and version tags usually lag HEAD.
    func check(userInitiated: Bool, completion: ((Result<Release?, Error>) -> Void)? = nil) {
        guard !Self.isLocalDevelopmentBuild() else {
            log.info("Skipping update check for local development build")
            completion?(.failure(UpdateError.localDevelopmentBuild))
            return
        }
        guard !isChecking else {
            log.info("Update check already in flight, skipping")
            // Still report back, or a caller like the Preferences "Check Now" button would sit
            // disabled on "Checking..." forever waiting for a completion that never comes.
            completion?(.failure(UpdateError.alreadyChecking))
            return
        }
        isChecking = true

        var request = URLRequest(url: Self.latestReleaseURL)
        // HEAD keeps this to headers only: the redirect target carries the version, so the
        // release page's HTML is never downloaded.
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                PreferencesManager.shared.lastUpdateCheckAt = Date()

                if let error = error {
                    log.error("Update check failed: \(error.localizedDescription)")
                    completion?(.failure(error))
                    return
                }
                guard let finalURL = (response as? HTTPURLResponse)?.url else {
                    completion?(.failure(UpdateError.badResponse))
                    return
                }
                guard let latest = Self.parseVersion(fromTagURL: finalURL) else {
                    log.error("Could not parse a version from \(finalURL.absoluteString, privacy: .public)")
                    completion?(.failure(UpdateError.unreadableVersion))
                    return
                }

                let current = Self.currentVersion()
                log.info("Latest release \(latest, privacy: .public), running \(current, privacy: .public)")

                guard Self.isNewer(latest, than: current) else {
                    completion?(.success(nil))
                    return
                }

                let release = Release(version: latest)
                completion?(.success(release))

                if userInitiated || self.lastPromptedVersion != latest {
                    self.lastPromptedVersion = latest
                    self.promptForUpdate(release, current: current)
                }
            }
        }.resume()
    }

    // MARK: - Prompting

    private func promptForUpdate(_ release: Release, current: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ThoughtQueue \(release.version) is available"
        alert.informativeText = "You're running \(current). ThoughtQueue will download the update, replace itself, and restart."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            log.info("User postponed update to \(release.version, privacy: .public)")
            return
        }
        install(release)
    }

    // MARK: - Installing

    /// Downloads, verifies, and swaps in the new build, then relaunches. Any failure before the
    /// swap leaves the installed app untouched and surfaces an alert.
    func install(_ release: Release) {
        let progress = ProgressAlert(text: "Downloading ThoughtQueue \(release.version)\u{2026}")
        progress.show()

        Task.detached(priority: .userInitiated) {
            do {
                let staged = try await Self.downloadAndStage(release)
                await MainActor.run {
                    progress.close()
                    self.swapAndRestart(newBundle: staged.bundleURL, workDir: staged.workDir)
                }
            } catch {
                await MainActor.run {
                    progress.close()
                    self.showInstallFailure(error, release: release)
                }
            }
        }
    }

    private struct StagedUpdate {
        let bundleURL: URL
        let workDir: URL
    }

    /// Fetches the zip and its checksum, verifies, unpacks, and validates the resulting bundle.
    /// Returns the staged `.app` in a temp directory. Throws before touching anything installed.
    private static func downloadAndStage(_ release: Release) async throws -> StagedUpdate {
        let zipName = "ThoughtQueue-\(release.version).zip"

        let (checksumData, _) = try await URLSession.shared.data(from: release.checksumsURL)
        let checksumText = String(data: checksumData, encoding: .utf8) ?? ""
        guard let expected = expectedSHA256(for: zipName, in: checksumText) else {
            throw UpdateError.checksumMissing(zipName)
        }

        let (zipData, _) = try await URLSession.shared.data(from: release.zipURL)
        let actual = sha256Hex(of: zipData)
        guard actual == expected else {
            throw UpdateError.checksumMismatch(expected: expected, got: actual)
        }
        log.info("Verified \(zipName, privacy: .public) against published checksum")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThoughtQueueUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zipURL = workDir.appendingPathComponent(zipName)
        try zipData.write(to: zipURL)

        let unpackDir = workDir.appendingPathComponent("unpacked")
        try unzip(zipURL, to: unpackDir)

        let bundleURL = unpackDir.appendingPathComponent("ThoughtQueue.app")
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw UpdateError.bundleMissing
        }
        try validate(bundleURL, expectedVersion: release.version)

        return StagedUpdate(bundleURL: bundleURL, workDir: workDir)
    }

    /// Unpacks a zip with ditto, which preserves the resource forks and symlinks a .app needs.
    private static func unzip(_ zip: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        // Read before waiting so a large error payload can't fill the pipe buffer and deadlock.
        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw UpdateError.unzipFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Rejects anything that isn't the ThoughtQueue we expected, so a wrong or tampered asset
    /// can't be moved over the installed app.
    private static func validate(_ bundleURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: bundleURL) else {
            throw UpdateError.bundleMismatch("unreadable bundle")
        }
        let expectedID = Bundle.main.bundleIdentifier ?? "com.thoughtqueue.app"
        guard bundle.bundleIdentifier == expectedID else {
            throw UpdateError.bundleMismatch("bundle id \(bundle.bundleIdentifier ?? "nil"), expected \(expectedID)")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            throw UpdateError.bundleMismatch("version \(version ?? "nil"), expected \(expectedVersion)")
        }
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/ThoughtQueue")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.bundleMismatch("missing executable")
        }
    }

    /// Hands the bundle swap to a detached shell script and quits. The swap has to happen after
    /// this process exits, so the running app is never partially replaced.
    private func swapAndRestart(newBundle: URL, workDir: URL) {
        let installed = Bundle.main.bundleURL
        let parent = installed.deletingLastPathComponent()

        let fm = FileManager.default
        guard fm.isWritableFile(atPath: installed.path), fm.isWritableFile(atPath: parent.path) else {
            try? fm.removeItem(at: workDir)
            showNotWritable(path: parent.path)
            return
        }

        do {
            let script = Self.swapScript(
                pid: ProcessInfo.processInfo.processIdentifier,
                installed: installed.path,
                staged: newBundle.path,
                workDir: workDir.path
            )
            let scriptURL = workDir.appendingPathComponent("swap.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()

            log.info("Swap helper launched, terminating for update")
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: workDir)
            showInstallFailure(error, release: nil)
        }
    }

    /// The helper that outlives the app: wait for it to exit, move the new bundle into place,
    /// roll back if that fails, then relaunch. Bounded wait so a cancelled quit (an unsaved note
    /// prompt, say) leaves the install alone instead of swapping under a live process.
    static func swapScript(pid: Int32, installed: String, staged: String, workDir: String) -> String {
        """
        #!/bin/sh
        PID=\(pid)
        INSTALLED=\(shellQuote(installed))
        STAGED=\(shellQuote(staged))
        WORKDIR=\(shellQuote(workDir))
        BACKUP="$INSTALLED.tq-old"

        waited=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
            waited=$((waited + 1))
            if [ "$waited" -gt 150 ]; then
                rm -rf "$WORKDIR"
                exit 1
            fi
        done

        rm -rf "$BACKUP"
        if ! mv "$INSTALLED" "$BACKUP"; then
            rm -rf "$WORKDIR"
            exit 1
        fi
        if ! mv "$STAGED" "$INSTALLED"; then
            mv "$BACKUP" "$INSTALLED"
            rm -rf "$WORKDIR"
            exit 1
        fi

        rm -rf "$BACKUP"
        xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null
        open -n "$INSTALLED"
        rm -rf "$WORKDIR"
        """
    }

    // MARK: - Failure alerts

    private func showNotWritable(path: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Can't update in place"
        alert.informativeText = UpdateError.notWritable(path).localizedDescription
            + "\n\nYou can download the update and install it manually instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repoSlug)/releases/latest")!)
        }
    }

    private func showInstallFailure(_ error: Error, release: Release?) {
        log.error("Update install failed: \(error.localizedDescription, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update failed"
        alert.informativeText = error.localizedDescription + "\n\nYour installed copy of ThoughtQueue was not changed."
        alert.alertStyle = .warning
        if let release = release {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

/// A borderless "working on it" window shown during the download. `NSAlert` can't be used here
/// because `runModal()` would block the download's completion hop back to the main thread.
private final class ProgressAlert {
    private var window: NSWindow?
    private let text: String

    init(text: String) {
        self.text = text
    }

    func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "ThoughtQueue"
        window.center()
        window.level = .floating

        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let stack = NSStackView(views: [label, spinner])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ])
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}
