import Foundation
import XCTest

/// Tests for `ZenttyResources/bin/shared/zentty-kiro-term`, the Q_TERM_PATH wrapper
/// that re-arms Zentty's shell-integration env after Kiro CLI's pre-block execs the
/// pane shell into figterm (dedene/zentty#95). The end-to-end tests replay that
/// chain with a fake figterm: outer `zsh -i` (Kiro pre-block in .zshrc execs the
/// wrapper) -> wrapper re-arms env -> fake figterm -> inner `zsh -i` must load the
/// integration again instead of losing it.
final class ShellIntegrationKiroTermTests: XCTestCase {
    private var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var kiroTermWrapperURL: URL {
        repositoryRootURL
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent("zentty-kiro-term", isDirectory: false)
    }

    private var shellIntegrationDirectoryURL: URL {
        repositoryRootURL
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
    }

    func test_wrapper_rearms_integration_env_before_exec() throws {
        let home = try makeTemporaryDirectory(named: "kiro-term-home")
        try writeFakeFigterm("env", into: home)

        let result = try run(
            executable: kiroTermWrapperURL.path,
            arguments: [],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "ZENTTY_SHELL_INTEGRATION_DIR": "/it/dir",
                "ZENTTY_SHELL_INTEGRATION_XDG_DIR": "/it/dir",
                "ZDOTDIR": "/users/zdot",
                "PROMPT_COMMAND": "history -a",
                "XDG_DATA_DIRS": "/it/dir:/usr/share",
                "Q_SHELL": "/bin/zsh",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)")
        XCTAssertEqual(envValue("ZDOTDIR", in: result.stdout), "/it/dir")
        XCTAssertEqual(envValue("ZENTTY_ORIGINAL_ZDOTDIR", in: result.stdout), "/users/zdot")
        XCTAssertEqual(envValue("ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND", in: result.stdout), "history -a")
        XCTAssertEqual(envValue("PROMPT_COMMAND", in: result.stdout), ". \"/it/dir/zentty-bash-integration.bash\"")
        XCTAssertEqual(envValue("XDG_DATA_DIRS", in: result.stdout), "/it/dir:/usr/share")
    }

    func test_wrapper_without_user_zdotdir_clears_original_and_keeps_own_hook() throws {
        let home = try makeTemporaryDirectory(named: "kiro-term-home-nozdot")
        try writeFakeFigterm("env", into: home)

        let result = try run(
            executable: kiroTermWrapperURL.path,
            arguments: [],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "ZENTTY_SHELL_INTEGRATION_DIR": "/it/dir",
                "ZENTTY_SHELL_INTEGRATION_XDG_DIR": "/it/dir",
                "ZENTTY_ORIGINAL_ZDOTDIR": "/stale",
                "PROMPT_COMMAND": "_zentty_bash_prompt_hook",
                "Q_SHELL": "/bin/zsh",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)")
        XCTAssertNil(envValue("ZENTTY_ORIGINAL_ZDOTDIR", in: result.stdout))
        XCTAssertEqual(envValue("ZDOTDIR", in: result.stdout), "/it/dir")
        XCTAssertNil(envValue("ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND", in: result.stdout))
        XCTAssertEqual(envValue("PROMPT_COMMAND", in: result.stdout), ". \"/it/dir/zentty-bash-integration.bash\"")
        XCTAssertEqual(envValue("XDG_DATA_DIRS", in: result.stdout), "/it/dir:/usr/local/share:/usr/share")
    }

    func test_wrapper_prefers_original_q_term_path() throws {
        let home = try makeTemporaryDirectory(named: "kiro-term-home-orig")
        try writeFakeFigterm("printf 'REAL=home\\n'", into: home)

        let alternateDirectory = try makeTemporaryDirectory(named: "kiro-term-alt")
        let alternateFigterm = alternateDirectory.appendingPathComponent("kiro-cli-term", isDirectory: false)
        try writeExecutable("#!/bin/sh\nprintf 'REAL=alt\\n'\n", to: alternateFigterm)

        let result = try run(
            executable: kiroTermWrapperURL.path,
            arguments: [],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "ZENTTY_ORIGINAL_Q_TERM_PATH": alternateFigterm.path,
                "Q_SHELL": "/bin/zsh",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "REAL=alt")
    }

    func test_wrapper_falls_back_to_shell_when_figterm_missing() throws {
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: "/usr/bin/kiro-cli-term")
                || FileManager.default.fileExists(atPath: "/bin/kiro-cli-term")
                || FileManager.default.isExecutableFile(
                    atPath: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-term"
                ),
            "A real kiro-cli-term is installed on this host; the missing-figterm fallback is unreachable"
        )

        let home = try makeTemporaryDirectory(named: "kiro-term-empty-home")
        let result = try run(
            executable: kiroTermWrapperURL.path,
            arguments: [],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "Q_SHELL": "/bin/sh",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("kiro-cli-term not found"), "stderr=\(result.stderr)")
    }

    func test_zsh_integration_survives_kiro_term_exec() throws {
        let fixture = try makeKiroTermFixture()
        let userZdotdir = try makeTemporaryDirectory(named: "kiro-term-user-zdotdir")
        try writeKiroPreBlockZshrc(to: userZdotdir.appendingPathComponent(".zshrc", isDirectory: false))

        let result = try runOuterZsh(
            fixture: fixture,
            extraEnvironment: ["ZENTTY_ORIGINAL_ZDOTDIR": userZdotdir.path]
        )

        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout)\nstderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("INTEGRATION=LOADED"), "stdout=\(result.stdout)")
        XCTAssertTrue(
            result.stdout.contains("RC_ZDOTDIR=\(userZdotdir.path)"),
            "user .zshrc must see its own ZDOTDIR, stdout=\(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("ZDOTDIR_NOW=\(userZdotdir.path)"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("ORIG=unset"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("LAUNCHED=1"), "stdout=\(result.stdout)")
        XCTAssertFalse(result.stdout.contains("OUTER_SHELL_SURVIVED"), "stdout=\(result.stdout)")

        let signals = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(signals.contains("shell-state prompt"), "signals=\(signals)")
    }

    func test_zsh_integration_survives_kiro_term_exec_without_user_zdotdir() throws {
        let fixture = try makeKiroTermFixture()
        try writeKiroPreBlockZshrc(to: fixture.homeURL.appendingPathComponent(".zshrc", isDirectory: false))

        let result = try runOuterZsh(fixture: fixture, extraEnvironment: [:])

        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout)\nstderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("INTEGRATION=LOADED"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("RC_ZDOTDIR=\n"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("ZDOTDIR_NOW=unset"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("ORIG=unset"), "stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("LAUNCHED=1"), "stdout=\(result.stdout)")
        XCTAssertFalse(result.stdout.contains("OUTER_SHELL_SURVIVED"), "stdout=\(result.stdout)")

        let signals = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(signals.contains("shell-state prompt"), "signals=\(signals)")
    }

    // MARK: - Fixture

    private struct KiroTermFixture {
        let homeURL: URL
        let logURL: URL
        let cliURL: URL
    }

    /// A temp HOME whose `.local/bin/kiro-cli-term` is a fake figterm: it marks the
    /// inner shell as Kiro-launched (like real figterm exporting Q_TERM) and execs
    /// a fresh interactive zsh running ZENTTY_TEST_INNER_COMMAND.
    private func makeKiroTermFixture() throws -> KiroTermFixture {
        let home = try makeTemporaryDirectory(named: "kiro-term-e2e-home")
        try writeFakeFigterm(
            """
            export PROCESS_LAUNCHED_BY_Q=1 Q_TERM=fake-2.21.4
            exec "$Q_SHELL" -i -c "$ZENTTY_TEST_INNER_COMMAND"
            """,
            into: home
        )

        let scratch = try makeTemporaryDirectory(named: "kiro-term-e2e-scratch")
        let cliURL = scratch.appendingPathComponent("zentty", isDirectory: false)
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$LOG_FILE\"\n",
            to: cliURL
        )

        return KiroTermFixture(
            homeURL: home,
            logURL: scratch.appendingPathComponent("signals.log", isDirectory: false),
            cliURL: cliURL
        )
    }

    /// Mimics the pre-block `kiro-cli integrations install` writes at the top of
    /// ~/.zshrc: while not already inside figterm, exec the pane shell into
    /// $Q_TERM_PATH (our wrapper). After exec the print reports the ZDOTDIR the
    /// user's rc actually saw.
    private func writeKiroPreBlockZshrc(to zshrcURL: URL) throws {
        try """
        if [[ -z "${PROCESS_LAUNCHED_BY_Q:-}" && -z "${Q_TERM:-}" ]]; then
          Q_SHELL="$ZENTTY_TEST_ZSH" exec -a "zsh (kiro-cli-term)" "$Q_TERM_PATH"
        fi
        print -r -- "RC_ZDOTDIR=$ZDOTDIR"
        """.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    /// Runs the outer pane zsh: Zentty's ZDOTDIR is already restored by our .zshenv,
    /// then the user's .zshrc (Kiro pre-block) execs the wrapper -> fake figterm ->
    /// inner zsh. With the fix the inner zsh re-loads the integration; without it
    /// INTEGRATION=MISSING.
    private func runOuterZsh(
        fixture: KiroTermFixture,
        extraEnvironment: [String: String]
    ) throws -> ProcessResult {
        var environment: [String: String] = [
            "HOME": fixture.homeURL.path,
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "peter",
            "PATH": "/usr/bin:/bin",
            "TTY": "/dev/null",
            "TERM": "dumb",
            "ZDOTDIR": shellIntegrationDirectoryURL.path,
            "ZENTTY_SHELL_INTEGRATION_DIR": shellIntegrationDirectoryURL.path,
            "ZENTTY_SHELL_INTEGRATION": "1",
            "Q_TERM_PATH": kiroTermWrapperURL.path,
            "ZENTTY_TEST_ZSH": "/bin/zsh",
            "ZENTTY_CLI_BIN": fixture.cliURL.path,
            "LOG_FILE": fixture.logURL.path,
            "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty-none.sock",
            "ZENTTY_PANE_TOKEN": "pane-token",
            "ZENTTY_TEST_INNER_COMMAND": """
                typeset -f _zentty_precmd >/dev/null && print INTEGRATION=LOADED || print INTEGRATION=MISSING
                print -r -- "ZDOTDIR_NOW=${ZDOTDIR-unset}"
                print -r -- "ORIG=${ZENTTY_ORIGINAL_ZDOTDIR-unset}"
                print -r -- "LAUNCHED=${PROCESS_LAUNCHED_BY_Q-unset}"
                """,
        ]
        extraEnvironment.forEach { environment[$0.key] = $0.value }

        return try run(
            executable: "/bin/zsh",
            arguments: ["-i", "-c", "print -r -- OUTER_SHELL_SURVIVED"],
            environment: environment,
            currentDirectory: fixture.homeURL
        )
    }

    // MARK: - Helpers

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct ProcessTimedOut: LocalizedError, CustomStringConvertible {
        let message: String

        var errorDescription: String? { message }
        var description: String { message }
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = XCTestExpectation(description: "kiro-term test process completed")
        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.fulfill()
            terminationSemaphore.signal()
        }

        try process.run()
        let waitResult = XCTWaiter().wait(for: [completion], timeout: timeout)
        guard waitResult == .completed else {
            if process.isRunning {
                process.terminate()
            }
            if terminationSemaphore.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 1)
            }
            let message = "kiro-term test process timed out after \(Int(timeout))s: \(executable) \(arguments)"
            XCTFail(message)
            throw ProcessTimedOut(message: message)
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    /// Installs `~/.local/bin/kiro-cli-term` as an executable /bin/sh script running
    /// the given body.
    private func writeFakeFigterm(_ body: String, into home: URL) throws {
        let localBin = home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try writeExecutable(
            "#!/bin/sh\n\(body)\n",
            to: localBin.appendingPathComponent("kiro-cli-term", isDirectory: false)
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func envValue(_ key: String, in envOutput: String) -> String? {
        for line in envOutput.split(separator: "\n") where line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
