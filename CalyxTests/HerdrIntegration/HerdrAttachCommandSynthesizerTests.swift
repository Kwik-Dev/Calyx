//
//  HerdrAttachCommandSynthesizerTests.swift
//  CalyxTests
//
//  Coverage for HerdrAttachCommandSynthesizer: the pure function
//  synthesizing a herdr attach command that pins the EXACT socket the
//  user clicked via the `HERDR_SOCKET_PATH` environment variable --
//  never a `--session <name>` flag (a name would have to be
//  re-resolved back to a socket path by herdr itself, a wrong-socket
//  risk on a name collision, and a directory-derived name shaped like a
//  flag, e.g. one starting with `-`, could otherwise be misparsed as an
//  option). Both `herdrBin` and `socketPath` are individually escaped
//  via the EXISTING SessionCommandSynthesizer.shSafeToken (never a new
//  escaper).
//
//  PRODUCTION PARSE, NOT A SIMPLIFIED ONE: every test below runs the
//  synthesized command through `/bin/bash --noprofile --norc -c
//  "exec -l <command>"` -- ghostty's own real wrapping of a pane's
//  configured `command` (SessionCommandSynthesizer.swift's own header;
//  see also SessionCommandSynthesizerRuntimeStateDirFlagsTests, which
//  fought the identical class of bug for calyx-session's own command).
//  This matters more here than almost anywhere else in the codebase: a
//  BARE `HERDR_SOCKET_PATH=<token> <token>` (no `/usr/bin/env` in
//  front) DOES work when run through a plain `/bin/sh -c <command>`
//  with no `exec` wrapper -- which is exactly why the earlier version
//  of this file, using that simplified harness, would NOT have caught
//  this -- but field-verified against the REAL wrapper, `exec -l`
//  already claims the command-word position for the `exec` builtin
//  itself, so a `NAME=value` word immediately after it is no longer in
//  POSIX "prefix assignment" position; it is just `exec`'s own next
//  argument, which `exec`'s builtin argument parsing treats as the
//  program to run, not as an environment assignment
//  (`bash: line 0: exec: HERDR_SOCKET_PATH=...: not found`,
//  confirmed empirically before this function was written this way --
//  this reproduces SessionCommandSynthesizerRuntimeStateDirFlagsTests'
//  own documented ROUND 1 HOME-stamp failure verbatim). Routing through
//  the hardcoded absolute path `/usr/bin/env` (always present on
//  Darwin, so no PATH-search ambiguity, and never escaped -- a fixed
//  constant, never attacker/user-controlled) fixes it: `exec -l` now
//  execs `/usr/bin/env` directly, and `env`'s OWN argument parsing --
//  which runs AFTER the shell has already removed quotes -- is what
//  turns the leading `NAME=value` word into a real environment
//  assignment before it execs the shell-escaped `herdrBin` word that
//  follows.
//
//  The dumper writes a literal "INVOKED" sentinel line first (so a
//  broken/unescaped herdrBin, which makes the shell fail to find it at
//  all, is distinguishable from a real run), then its own observed
//  `$HERDR_SOCKET_PATH`, then each of its own argv words -- all
//  NUL-delimited (not newline-joined) so a hostile socketPath can
//  itself CONTAIN a raw newline/CRLF and still round-trip intact.
//
//  Coverage:
//  - Default shape: HERDR_SOCKET_PATH is set to socketPath verbatim,
//    herdrBin is invoked with zero arguments -- no --session flag, ever
//  - herdrBin containing a space survives as one exec'd word
//  - Hostile socketPath values -- single quote + shell metacharacters, a
//    bare newline, a CRLF pair, spaces, a value starting with `-`
//    (the core finding-9 regression pin: never reaches herdrBin as an
//    argv word at all, so it has no flag-parsing surface to exploit) --
//    each survive as the exact HERDR_SOCKET_PATH value, byte-for-byte
//

import XCTest
@testable import Calyx

final class HerdrAttachCommandSynthesizerTests: XCTestCase {

    // MARK: - Shared helpers

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Runs `command` exactly the way ghostty invokes a pane's
    /// configured `command`: `/bin/bash --noprofile --norc -c "exec -l
    /// <command>"` (SessionCommandSynthesizer.swift's own header) --
    /// see this file's header for why this specific wrapper, not a bare
    /// `/bin/sh -c`, is load-bearing here.
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
    /// exec'd, ALWAYS writes a literal "INVOKED\n" line to `outputPath`
    /// first, then its own observed `$HERDR_SOCKET_PATH` NUL-terminated,
    /// then each of its own argv words NUL-terminated -- see this
    /// file's header comment for why both the sentinel and
    /// NUL-delimiting are load-bearing.
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

    /// `nil` when the dumper never ran at all (no output file, or a
    /// file missing the leading "INVOKED" sentinel). Otherwise the
    /// captured `$HERDR_SOCKET_PATH` value plus any trailing argv words
    /// (expected to always be empty -- no --session flag exists in this
    /// design).
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
    /// command for `socketPath` (and `herdrBin`, when a hostile
    /// herdrBin needs to be pinned instead of a fresh temp path), runs
    /// it through the real ghostty wrapper, and asserts
    /// `$HERDR_SOCKET_PATH` survives verbatim with zero argv words.
    private func assertSocketPathSurvives(
        _ socketPath: String, herdrBin: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let binaryPath = herdrBin ?? uniqueTempPath("herdr-dumper")
        let outputPath = uniqueTempPath("herdr-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeDumperScript(at: binaryPath, outputPath: outputPath)

        let command = HerdrAttachCommandSynthesizer.attachCommand(herdrBin: binaryPath, socketPath: socketPath)
        try runEmulatingGhosttyWrapping(command)
        let captured = readCapture(at: outputPath)

        XCTAssertEqual(captured?.socketPath, socketPath,
                       "expected HERDR_SOCKET_PATH to survive as \(socketPath.debugDescription) (INVOKED " +
                       "sentinel present, proving the dumper actually ran), got " +
                       "\(captured?.socketPath.debugDescription ?? "nil (dumper never ran)")",
                       file: file, line: line)
        XCTAssertEqual(captured?.argv, [],
                       "no --session flag or any other argument must ever reach herdrBin",
                       file: file, line: line)
    }

    // MARK: - Default shape

    func test_attachCommand_setsHerdrSocketPathEnvVar_andInvokesHerdrBinWithZeroArguments() throws {
        try assertSocketPathSurvives("/Users/dev/.config/herdr/herdr.sock")
    }

    // MARK: - herdrBin escaping

    func test_attachCommand_herdrBinWithSpace_isInvokedCorrectly() throws {
        let dirWithSpace = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr dumper dir \(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dirWithSpace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dirWithSpace) }

        try assertSocketPathSurvives("/Users/dev/.config/herdr/herdr.sock", herdrBin: dirWithSpace + "/herdr")
    }

    // MARK: - Hostile socketPath values

    func test_attachCommand_socketPathWithSingleQuoteAndShellMetacharacters_survivesIntact() throws {
        // Harmless-if-ever-actually-executed, matching
        // SessionCommandSynthesizerTests' own precedent: `touch` with
        // no operand is a no-op usage error, never destructive, even
        // in the hypothetical case escaping were broken.
        try assertSocketPathSurvives("/tmp/herdr-sessions/work'; touch; #/herdr.sock")
    }

    func test_attachCommand_socketPathWithNewline_survivesIntact() throws {
        try assertSocketPathSurvives("/tmp/herdr-sessions/work\nsecond-line/herdr.sock")
    }

    func test_attachCommand_socketPathWithCRLF_survivesIntact() throws {
        try assertSocketPathSurvives("/tmp/herdr-sessions/work\r\nsecond-line/herdr.sock")
    }

    func test_attachCommand_socketPathWithSpaces_survivesIntact() throws {
        try assertSocketPathSurvives("/tmp/herdr-sessions/my session with spaces/herdr.sock")
    }

    func test_attachCommand_socketPathStartingWithDash_neverMisparsedAsAFlag() throws {
        // The core finding-9 regression pin: a socketPath (ultimately
        // derived from a sessions/ subdirectory's own name) that LOOKS
        // like a CLI flag must never reach herdrBin as an argv word at
        // all -- it only ever travels as the HERDR_SOCKET_PATH env
        // var's VALUE, which has no flag-parsing semantics whatsoever.
        try assertSocketPathSurvives("/tmp/herdr-sessions/--session/herdr.sock")
    }
}
