import Cocoa

struct NetConfig {
    let allowlist: [String]
    let interval: Int
}

final class PrivilegedRunner {
    func run(script: String) -> Bool {
        let escaped = escapeForAppleScript(script)
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        guard let compiled = NSAppleScript(source: appleScript) else {
            showError(message: "Failed to create AppleScript.")
            return false
        }

        compiled.executeAndReturnError(&error)

        if let error = error,
           let code = error[NSAppleScript.errorNumber] as? Int,
           code == -128 {
            return false
        }

        if let error = error {
            showError(message: error.description)
            return false
        }

        return true
    }

    private func escapeForAppleScript(_ input: String) -> String {
        var output = input.replacingOccurrences(of: "\\", with: "\\\\")
        output = output.replacingOccurrences(of: "\"", with: "\\\"")
        return output
    }

    private func showError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "MenuBarNetToggle"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

final class NetEnforcementController {
    private let runner = PrivilegedRunner()

    private let daemonLabel = "com.codex.netenforce"
    private let helperDir = "/Library/Application Support/MenuBarNetToggle"
    private let helperScriptPath = "/Library/Application Support/MenuBarNetToggle/enforce.sh"
    private let configPath = "/Library/Application Support/MenuBarNetToggle/config.conf"
    private let daemonPlistPath = "/Library/LaunchDaemons/com.codex.netenforce.plist"
    private let pidFile = "/var/run/com.codex.netenforce.pid"

    func defaultConfig() -> NetConfig {
        return NetConfig(allowlist: ["en0", "utun4", "lo0"], interval: 15)
    }

    func readConfig() -> NetConfig {
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return defaultConfig()
        }

        var allowlist = defaultConfig().allowlist
        var interval = defaultConfig().interval

        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ALLOWLIST=") {
                let value = String(trimmed.dropFirst("ALLOWLIST=".count))
                allowlist = parseAllowlist(value) ?? allowlist
            } else if trimmed.hasPrefix("INTERVAL=") {
                let value = String(trimmed.dropFirst("INTERVAL=".count))
                if let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 1 {
                    interval = parsed
                }
            }
        }

        return NetConfig(allowlist: allowlist, interval: interval)
    }

    func isEnforcing() -> Bool {
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8) else {
            return false
        }

        let trimmed = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    func startEnforcing(config: NetConfig) {
        let script = makeInstallAndStartScript(config: config)
        _ = runner.run(script: script)
    }

    func stopEnforcing() {
        let script = makeStopScript()
        _ = runner.run(script: script)
    }

    func updateConfig(_ config: NetConfig) {
        let script = makeWriteConfigScript(config: config)
        _ = runner.run(script: script)
    }

    enum ConfigValidationError: Error {
        case message(String)
    }

    func validateConfig(allowlistText: String, intervalText: String) -> Result<NetConfig, ConfigValidationError> {
        let trimmed = allowlistText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.message("Allowlist cannot be empty."))
        }

        let tokens = trimmed.replacingOccurrences(of: ",", with: " ")
            .split { $0 == " " || $0 == "\n" || $0 == "\t" }

        var allowlist: [String] = []
        var seen = Set<String>()
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))

        for tokenSub in tokens {
            let token = String(tokenSub)
            if token.rangeOfCharacter(from: allowedChars.inverted) != nil {
                return .failure(.message("Invalid interface name: \(token)"))
            }
            if !seen.contains(token) {
                seen.insert(token)
                allowlist.append(token)
            }
        }

        if allowlist.isEmpty {
            return .failure(.message("Allowlist cannot be empty."))
        }

        let intervalTrimmed = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let interval = Int(intervalTrimmed), interval >= 1, interval <= 3600 else {
            return .failure(.message("Interval must be a number between 1 and 3600 seconds."))
        }

        return .success(NetConfig(allowlist: allowlist, interval: interval))
    }

    private func parseAllowlist(_ value: String) -> [String]? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        let tokens = trimmed.replacingOccurrences(of: ",", with: " ")
            .split { $0 == " " || $0 == "\n" || $0 == "\t" }

        if tokens.isEmpty {
            return nil
        }

        return tokens.map { String($0) }
    }

    private func makeWriteConfigScript(config: NetConfig) -> String {
        let allowlistText = config.allowlist.joined(separator: " ")
        return """
        /bin/mkdir -p "\(helperDir)"
        /usr/bin/tee "\(configPath)" >/dev/null <<'EOF'
        ALLOWLIST="\(allowlistText)"
        INTERVAL=\(config.interval)
        EOF
        /usr/sbin/chown root:wheel "\(configPath)"
        /bin/chmod 644 "\(configPath)"
        """
    }

    private func makeInstallAndStartScript(config: NetConfig) -> String {
        let allowlistText = config.allowlist.joined(separator: " ")
        return """
        /bin/mkdir -p "\(helperDir)"
        /usr/bin/tee "\(configPath)" >/dev/null <<'EOF'
        ALLOWLIST="\(allowlistText)"
        INTERVAL=\(config.interval)
        EOF
        /usr/sbin/chown root:wheel "\(configPath)"
        /bin/chmod 644 "\(configPath)"

        /usr/bin/tee "\(helperScriptPath)" >/dev/null <<'EOF'
        #!/bin/sh
        CONFIG="\(configPath)"
        PIDFILE="\(pidFile)"
        DEFAULT_ALLOWLIST="\(allowlistText)"
        DEFAULT_INTERVAL=\(config.interval)

        echo $$ > "$PIDFILE"
        /bin/chmod 644 "$PIDFILE"
        trap 'rm -f "$PIDFILE"; exit 0' INT TERM

        while true; do
          ALLOWLIST="$DEFAULT_ALLOWLIST"
          INTERVAL=$DEFAULT_INTERVAL

          if [ -f "$CONFIG" ]; then
            . "$CONFIG"
          fi

          if [ -z "$INTERVAL" ]; then
            INTERVAL=$DEFAULT_INTERVAL
          fi

          if [ "$INTERVAL" -lt 1 ] 2>/dev/null; then
            INTERVAL=$DEFAULT_INTERVAL
          fi

          for i in $(/sbin/ifconfig -l); do
            skip=0
            for a in $ALLOWLIST; do
              if [ "$i" = "$a" ]; then
                skip=1
                break
              fi
            done
            if [ $skip -eq 0 ]; then
              /sbin/ifconfig "$i" down
            fi
          done

          /bin/sleep "$INTERVAL"
        done
        EOF
        /usr/sbin/chown root:wheel "\(helperScriptPath)"
        /bin/chmod 755 "\(helperScriptPath)"

        /usr/bin/tee "\(daemonPlistPath)" >/dev/null <<'EOF'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>\(helperScriptPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/\(daemonLabel).out</string>
            <key>StandardErrorPath</key>
            <string>/var/log/\(daemonLabel).err</string>
        </dict>
        </plist>
        EOF
        /usr/sbin/chown root:wheel "\(daemonPlistPath)"
        /bin/chmod 644 "\(daemonPlistPath)"

        if /bin/launchctl print system/\(daemonLabel) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k system/\(daemonLabel) >/dev/null 2>&1 || true
        else
          /bin/launchctl bootstrap system "\(daemonPlistPath)" >/dev/null 2>&1 || true
        fi
        """
    }

    private func makeStopScript() -> String {
        return """
        /bin/launchctl bootout system/\(daemonLabel) >/dev/null 2>&1 || /bin/launchctl bootout system "\(daemonPlistPath)" >/dev/null 2>&1 || true
        /bin/rm -f "\(pidFile)"
        """
    }
}

final class LoginItemManager {
    private let label = "com.codex.MenuBarNetToggle"

    private var plistPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    func isEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: plistPath)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            writePlist()
            bootstrap()
        } else {
            bootout()
            removePlist()
        }
    }

    private func writePlist() {
        let appPath = Bundle.main.bundlePath
        let execPath = "\(appPath)/Contents/MacOS/MenuBarNetToggle"

        let plist = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        do {
            let url = URL(fileURLWithPath: plistPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(message: "Failed to write LaunchAgent: \(error.localizedDescription)")
        }
    }

    private func bootstrap() {
        let uid = getuid()
        runProcess("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        runProcess("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
    }

    private func bootout() {
        let uid = getuid()
        runProcess("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    }

    private func removePlist() {
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private func showError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "MenuBarNetToggle"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = NetEnforcementController()
    private let loginManager = LoginItemManager()

    private var statusItem: NSStatusItem!
    private var enforcementItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.title = "NetCtl ○"

        let menu = NSMenu()
        menu.delegate = self

        enforcementItem = NSMenuItem(title: "Enforcement: Off", action: #selector(toggleEnforcement), keyEquivalent: "")
        enforcementItem.target = self
        menu.addItem(enforcementItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshUI()

        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    @objc private func toggleEnforcement() {
        if controller.isEnforcing() {
            controller.stopEnforcing()
        } else {
            let config = controller.readConfig()
            controller.startEnforcing(config: config)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshUI()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = loginManager.isEnabled()
        loginManager.setEnabled(!enabled)
        refreshUI()
    }

    @objc private func openSettings() {
        let current = controller.readConfig()

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Network Enforcement Settings"
        alert.informativeText = "Edit the allowlist and interval (seconds)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let allowLabel = NSTextField(labelWithString: "Allowlist (space or comma separated):")
        let allowField = NSTextField(string: current.allowlist.joined(separator: " "))
        let intervalLabel = NSTextField(labelWithString: "Interval (seconds):")
        let intervalField = NSTextField(string: "\(current.interval)")

        allowField.isEditable = true
        allowField.isSelectable = true
        allowField.isBezeled = true
        allowField.drawsBackground = true

        intervalField.isEditable = true
        intervalField.isSelectable = true
        intervalField.isBezeled = true
        intervalField.drawsBackground = true

        let width: CGFloat = 360
        let height: CGFloat = 120
        let labelHeight: CGFloat = 16
        let fieldHeight: CGFloat = 22
        let padding: CGFloat = 8

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - labelHeight

        allowLabel.frame = NSRect(x: 0, y: y, width: width, height: labelHeight)
        y -= fieldHeight + 4
        allowField.frame = NSRect(x: 0, y: y, width: width, height: fieldHeight)

        y -= labelHeight + padding
        intervalLabel.frame = NSRect(x: 0, y: y, width: width, height: labelHeight)
        y -= fieldHeight + 4
        intervalField.frame = NSRect(x: 0, y: y, width: width, height: fieldHeight)

        container.addSubview(allowLabel)
        container.addSubview(allowField)
        container.addSubview(intervalLabel)
        container.addSubview(intervalField)

        alert.accessoryView = container
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = allowField
        alertWindow.makeFirstResponder(allowField)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let allowText = allowField.stringValue
            let intervalText = intervalField.stringValue

            switch controller.validateConfig(allowlistText: allowText, intervalText: intervalText) {
            case .success(let config):
                controller.updateConfig(config)
            case .failure(let error):
                switch error {
                case .message(let message):
                    showError(message: message)
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshUI() {
        let enforcing = controller.isEnforcing()
        enforcementItem.title = enforcing ? "Enforcement: On" : "Enforcement: Off"
        enforcementItem.state = enforcing ? .on : .off
        launchAtLoginItem.state = loginManager.isEnabled() ? .on : .off

        statusItem.button?.title = enforcing ? "NetCtl ●" : "NetCtl ○"
    }

    private func showError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "MenuBarNetToggle"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
