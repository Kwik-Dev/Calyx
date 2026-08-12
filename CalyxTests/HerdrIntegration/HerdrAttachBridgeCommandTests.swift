//
//  HerdrAttachBridgeCommandTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrAttachBridgeCommand: the pure function
//  synthesizing PER-PANE bridge command --
//  `/usr/bin/env HERDR_SOCKET_PATH=<socketPath> <herdrBin> terminal attach
//  <terminalID>` -- as opposed to HerdrAttachCommandSynthesizer's
//  whole-session TUI attach command (`<herdrBin>` alone, zero
//  arguments). Every VARIABLE token (socketPath, herdrBin, terminalID) is
//  passed through the EXISTING SessionCommandSynthesizer.shSafeToken --
//  never a new escaper -- exactly like HerdrAttachCommandSynthesizer
//  already does; the literal words `/usr/bin/env`, `terminal`, `attach`
//  are fixed constants and are never escaped, mirroring
//  HerdrAttachCommandSynthesizer's own precedent of leaving
//  `/usr/bin/env` bare and SessionCommandSynthesizer.attachCommand's own
//  precedent of leaving `attach`/`--create`/`--cwd` bare.
//
//  `terminal attach`, NOT `agent attach`: `herdr agent attach <paneID>`
//  resolves its target through herdr's AGENT registry and fails outright
//  for any pane with no agent running. `herdr terminal attach
//  <terminalID>` is the measured, working replacement -- see
//  HerdrAttachBridgeCommand.swift's own header for the live verification
//  this rests on.
//
//  build(herdrBin:socketPath:terminalID:) returns `String?`, not `String`:
//  it gates on HerdrPaneRef.isValidTerminalID(terminalID) FIRST and
//  returns nil for anything that validator rejects -- see
//  HerdrPaneRefTests.swift for the full acceptance/rejection table this
//  gate is built on. A command must never be synthesized around a
//  terminalID shaped like a shell injection attempt, regardless of how
//  well shSafeToken would have escaped it in practice.
//
//  WHY `/usr/bin/env` (env-prefix requirement, mirroring
//  HerdrAttachCommandSynthesizer.swift's own header verbatim): ghostty
//  wraps whatever `command` a surface configures as
//  `/bin/bash --noprofile --norc -c "exec -l <command>"`
//  (SessionCommandSynthesizer.swift's own header). By the time that
//  string is parsed, `exec -l` has already claimed the command-word
//  position for the `exec` builtin itself, so a bare
//  `HERDR_SOCKET_PATH=<token> <token> terminal attach <token>` (no
//  `/usr/bin/env` in front) would put `HERDR_SOCKET_PATH=...` in
//  `exec`'s own next-argument position, which `exec`'s builtin argument
//  parsing treats as the program to run, not as an environment
//  assignment -- reproducing HerdrAttachCommandSynthesizerTests' own
//  documented failure mode verbatim. Routing through the hardcoded
//  absolute path `/usr/bin/env` fixes it exactly as it does there.
//
//  PRODUCTION PARSE, NOT A SIMPLIFIED ONE: every execution-based test
//  below runs the synthesized command through the SAME real wrapper
//  HerdrAttachCommandSynthesizerTests.swift established --
//  `/bin/bash --noprofile --norc -c "exec -l <command>"` -- for the
//  identical reason documented there: a bare `/bin/sh -c <command>`
//  harness (no `exec` wrapper) would not catch a missing
//  `/usr/bin/env`.
//

import XCTest
@testable import Calyx

final class HerdrAttachBridgeCommandTests: XCTestCase {

    // MARK: - Shared execution helpers (adapted from HerdrAttachCommandSynthesizerTests.swift)

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Runs `command` exactly the way ghostty invokes a pane's configured
    /// `command` -- see this file's header for why this specific
    /// wrapper, not a bare `/bin/sh -c`, is load-bearing here.
    private func runEmulatingGhosttyWrapping(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l " + command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Writes a `#!/bin/sh` dumper script at `scriptPath` that, when
    /// exec'd, always writes a literal "INVOKED\n" sentinel to
    /// `outputPath` first (so a broken/unescaped herdrBin, which makes
    /// the shell fail to find it at all, is distinguishable from a real
    /// run), then its own observed `$HERDR_SOCKET_PATH`, then each of its
    /// own argv words -- all NUL-delimited so a hostile socketPath or
    /// paneID can itself contain a raw newline/CRLF and still round-trip
    /// intact.
    private func makeDumperScript(at scriptPath: String, outputPath: String) throws {
        let body = """
        #!/bin/sh
        printf 'INVOKED\\n' >> "\(outputPath)"
        printf '%s\\0' "$HERDR_SOCKET_PATH" >> "\(outputPath)"
        for a in "$@"; do printf '%s\\0' "$a" >> "\(outputPath)"; done
        """
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    /// `nil` when the dumper never ran at all (no output file, or a file
    /// missing the leading "INVOKED" sentinel). Otherwise the captured
    /// `$HERDR_SOCKET_PATH` value plus every trailing argv word.
    private func readCapture(at outputPath: String) -> (socketPath: String, argv: [String])? {
        guard let data = FileManager.default.contents(atPath: outputPath) else { return nil }
        let bytes = [UInt8](data)
        let sentinel = Array("INVOKED\n".utf8)
        guard bytes.count >= sentinel.count, Array(bytes.prefix(sentinel.count)) == sentinel else {
            return nil
        }
        var rest = Array(bytes.dropFirst(sentinel.count))
        guard !rest.isEmpty, rest.last == 0 else { return nil }
        rest.removeLast() // drop the final trailing NUL delimiter
        let fields = rest.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let socketPath = fields.first else { return nil }
        return (socketPath, Array(fields.dropFirst()))
    }

    /// Builds a FRESH dumper-script/output-file pair, synthesizes the
    /// bridge command for `socketPath`/`terminalID` (and `herdrBin`, when
    /// a hostile herdrBin needs to be pinned instead of a fresh temp
    /// path), runs it through the real ghostty wrapper, and asserts
    /// `$HERDR_SOCKET_PATH` survives verbatim AND the dumper's own argv
    /// is exactly ["terminal", "attach", terminalID].
    private func assertBridgeCommandSurvives(
        socketPath: String, terminalID: String, herdrBin: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let binaryPath = herdrBin ?? uniqueTempPath("herdr-bridge-dumper")
        let outputPath = uniqueTempPath("herdr-bridge-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeDumperScript(at: binaryPath, outputPath: outputPath)

        guard let command = HerdrAttachBridgeCommand.build(herdrBin: binaryPath, socketPath: socketPath, terminalID: terminalID) else {
            XCTFail("expected a non-nil command for a valid terminalID \(terminalID.debugDescription)", file: file, line: line)
            return
        }
        try runEmulatingGhosttyWrapping(command)
        let captured = readCapture(at: outputPath)

        XCTAssertEqual(captured?.socketPath, socketPath,
                       "expected HERDR_SOCKET_PATH to survive as \(socketPath.debugDescription) (INVOKED sentinel present, " +
                       "proving the dumper actually ran), got \(captured?.socketPath.debugDescription ?? "nil (dumper never ran)")",
                       file: file, line: line)
        XCTAssertEqual(captured?.argv, ["terminal", "attach", terminalID],
                       "expected argv exactly [\"terminal\", \"attach\", \(terminalID.debugDescription)]",
                       file: file, line: line)
    }

    // MARK: - Default shape (exact expected string)

    func test_build_plainBinaryPathAndTerminalID_producesExactExpectedString() {
        let result = HerdrAttachBridgeCommand.build(
            herdrBin: "/opt/homebrew/bin/herdr",
            socketPath: "/Users/dev/.config/herdr/herdr.sock",
            terminalID: "term_658cabe34ba1713"
        )

        // Hand-written literal (not built by calling shSafeToken in this
        // test): shSafeToken(s) always wraps s in single quotes, and
        // none of these three inputs contain a "'" byte, so each token
        // below is simply its own value wrapped in a pair of "'"
        // characters. Only the three VARIABLE tokens are escaped; the
        // literal words `/usr/bin/env`, `terminal`, `attach` stay bare --
        // see this file's header.
        let expected = "/usr/bin/env HERDR_SOCKET_PATH='/Users/dev/.config/herdr/herdr.sock' '/opt/homebrew/bin/herdr' terminal attach 'term_658cabe34ba1713'"

        XCTAssertEqual(result, expected)
    }

    // MARK: - herdrBin escaping

    func test_build_herdrBinWithSpaceAndSingleQuote_isInvokedAsOneWord() throws {
        let dirWithSpaceAndQuote = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr's bridge dir \(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dirWithSpaceAndQuote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dirWithSpaceAndQuote) }

        try assertBridgeCommandSurvives(
            socketPath: "/Users/dev/.config/herdr/herdr.sock", terminalID: "term_658cabe34ba1713",
            herdrBin: dirWithSpaceAndQuote + "/herdr"
        )
    }

    // MARK: - Invalid terminalID -> nil

    func test_build_invalidTerminalID_returnsNilForEveryHostileOrMalformedID() {
        // Subset of HerdrPaneRefTests' own isValidTerminalID
        // acceptance/rejection table -- this only needs to prove the gate
        // is actually applied here, not re-verify isValidTerminalID's own
        // full behavior.
        let invalidTerminalIDs = [
            "",
            "term1",
            "term_658cabe34ba1713; touch; #",
            "term_658cabe34ba1713 extra",
        ]
        for terminalID in invalidTerminalIDs {
            XCTAssertNil(
                HerdrAttachBridgeCommand.build(herdrBin: "/opt/homebrew/bin/herdr", socketPath: "/tmp/herdr.sock", terminalID: terminalID),
                "expected nil for invalid terminalID \(terminalID.debugDescription) -- never emit a command for an id HerdrPaneRef.isValidTerminalID rejects"
            )
        }
    }

    // MARK: - HERDR_SOCKET_PATH env prefix (mirrors HerdrAttachCommandSynthesizer's own shape)

    func test_build_setsHerdrSocketPathEnvVar_forPlainSocketPath() throws {
        try assertBridgeCommandSurvives(socketPath: "/Users/dev/.config/herdr/herdr.sock", terminalID: "term_658cabe34ba1713")
    }

    func test_build_socketPathStartingWithDash_neverMisparsedAsFlag() throws {
        // Regression pin mirroring HerdrAttachCommandSynthesizerTests'
        // own "finding-9" case: a socketPath that LOOKS like a CLI flag
        // must never reach herdrBin as an argv word -- it only ever
        // travels as the HERDR_SOCKET_PATH env var's VALUE.
        try assertBridgeCommandSurvives(socketPath: "/tmp/herdr-sessions/--session/herdr.sock", terminalID: "term_658cabe34ba1713")
    }

    func test_build_socketPathWithSingleQuoteAndShellMetacharacters_survivesIntact() throws {
        // Harmless-if-ever-actually-executed, matching
        // HerdrAttachCommandSynthesizerTests' own precedent.
        try assertBridgeCommandSurvives(socketPath: "/tmp/herdr-sessions/work'; touch; #/herdr.sock", terminalID: "term_658cabe34ba1713")
    }
}
