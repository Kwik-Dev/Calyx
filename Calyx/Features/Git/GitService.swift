// GitService.swift
// Calyx
//
// Executes git commands and parses output. All methods run off-main-thread.

import Foundation

/// One record of `git worktree list --porcelain`. `path` is the only
/// attribute the porcelain schema guarantees; everything else is optional
/// or a bare flag label.
struct GitWorktreeInfo: Equatable, Sendable {
    let path: String
    let headOID: String?
    /// Full ref name such as `refs/heads/main`. Mutually exclusive with `isDetached`.
    let branchRef: String?
    let isDetached: Bool
    let isBare: Bool
    let isLocked: Bool
    let lockReason: String?
    let isPrunable: Bool
    let prunableReason: String?

    init(
        path: String,
        headOID: String? = nil,
        branchRef: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil
    ) {
        self.path = path
        self.headOID = headOID
        self.branchRef = branchRef
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }
}

/// One submodule of a superproject, as its index records it. The index is
/// the only place git validates the path: `.gitmodules` is a tracked text
/// file whose declarations nothing checks.
struct GitSubmoduleInfo: Equatable, Sendable {
    /// Relative to the superproject's work-tree root.
    let path: String
}

/// What HEAD resolves to. A detached HEAD has no branch, and a HEAD before
/// the first commit names no commit, so both halves can be absent.
struct GitHeadSummary: Equatable, Sendable {
    let branch: String?
    let shortHash: String?
}

enum GitService {
    enum GitError: Error, LocalizedError {
        case notARepository
        case gitNotFound
        case permissionDenied(path: String)
        case commandFailed(exitCode: Int32, stderr: String, command: String)
        case timeout(command: String)
        case diffTooLarge(path: String, size: Int)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                "Not a git repository"
            case .gitNotFound:
                "git not found at /usr/bin/git"
            case .permissionDenied(let path):
                "Permission denied: \(path)"
            case .commandFailed(let exitCode, let stderr, let command):
                "git \(command) failed (exit \(exitCode)): \(stderr)"
            case .timeout(let command):
                "git \(command) timed out"
            case .diffTooLarge(let path, let size):
                "Diff too large for \(path) (\(size) bytes)"
            }
        }
    }

    private static let gitPath = "/usr/bin/git"
    private static let maxDiffSize = 1_000_000

    // MARK: - Public API

    static func repoRoot(workDir: String) async throws -> String {
        let output = try await run(args: ["rev-parse", "--show-toplevel"], workDir: workDir)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func repositoryLocation(workDir: String) async throws -> GitRepositoryLocation {
        let output = try await run(
            args: [
                "rev-parse", "--show-toplevel", "--path-format=absolute",
                "--git-dir", "--git-common-dir",
            ],
            workDir: workDir
        )
        let paths = output.split(whereSeparator: \.isNewline).map(String.init)
        guard paths.count == 3 else {
            throw GitError.commandFailed(
                exitCode: -1,
                stderr: "Unexpected git repository metadata",
                command: "rev-parse"
            )
        }
        return GitRepositoryLocation(
            workTree: paths[0],
            gitDirectory: paths[1],
            gitCommonDirectory: paths[2]
        )
    }

    static func isGitRepository(workDir: String) async -> Bool {
        do {
            _ = try await repoRoot(workDir: workDir)
            return true
        } catch {
            return false
        }
    }

    static func gitStatus(workDir: String) async throws -> [GitFileEntry] {
        let output = try await run(args: ["status", "--porcelain=v2", "-z"], workDir: workDir)
        return parseStatus(output)
    }

    /// Every worktree attached to the repository containing `workDir`,
    /// including the main worktree (or the bare repository itself) first.
    static func worktreeList(workDir: String) async throws -> [GitWorktreeInfo] {
        let output = try await run(args: ["worktree", "list", "--porcelain", "-z"], workDir: workDir)
        return parseWorktreeList(output)
    }

    /// Every submodule recorded in the index of the repository rooted at
    /// `repoRoot`, in index order. Whether a submodule's directory is
    /// actually filled in is a separate question this does not answer.
    static func submoduleList(repoRoot: String) async throws -> [GitSubmoduleInfo] {
        let output = try await run(args: ["ls-files", "-z", "--stage"], workDir: repoRoot)
        return parseIndexGitlinks(output)
    }

    /// The gitlinks in `git ls-files -z --stage` output. Each record is
    /// `<mode> <sha> <stage>`, a tab, then the path, NUL-terminated, and
    /// mode 160000 is a gitlink. `-z` leaves the path unquoted, so it can
    /// hold spaces and tabs of its own and only the first tab separates
    /// it from the fields. A path an unresolved merge lists once per
    /// stage is still one submodule. The index of a large repository runs
    /// to hundreds of thousands of entries, so the scan stays on the UTF-8
    /// bytes (0x00 ends a record, 0x09 is the tab) and only the gitlink
    /// paths become Strings.
    static func parseIndexGitlinks(_ output: String) -> [GitSubmoduleInfo] {
        let gitlinkMode = Array("160000 ".utf8)
        var seenPaths: Set<String> = []
        var submodules: [GitSubmoduleInfo] = []
        for record in output.utf8.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.starts(with: gitlinkMode),
                  let tabIndex = record.firstIndex(of: 0x09) else { continue }
            let path = String(decoding: record[record.index(after: tabIndex)...], as: UTF8.self)
            guard seenPaths.insert(path).inserted else { continue }
            submodules.append(GitSubmoduleInfo(path: path))
        }
        return submodules
    }

    /// The branch and abbreviated commit HEAD points at. The two queries
    /// are independent, so they run concurrently.
    static func headSummary(workDir: String) async throws -> GitHeadSummary {
        async let branch = runReportingNoAnswerAsNil(
            args: ["symbolic-ref", "--short", "-q", "HEAD"], workDir: workDir
        )
        // `-q --verify` is what makes an unborn HEAD exit 1 instead of the
        // 128 a plain `rev-parse --short HEAD` returns, which a corrupt
        // repository returns as well.
        async let shortHash = runReportingNoAnswerAsNil(
            args: ["rev-parse", "--short", "-q", "--verify", "HEAD"], workDir: workDir
        )
        return try await GitHeadSummary(branch: branch, shortHash: shortHash)
    }

    /// The work tree of the superproject this repository is a submodule
    /// of, or `nil` when it is not one. A repository that is nobody's
    /// submodule answers with no output and exit 0.
    static func superprojectWorkTree(workDir: String) async throws -> String? {
        let output = try await run(
            args: ["rev-parse", "--show-superproject-working-tree"], workDir: workDir
        )
        let workTree = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return workTree.isEmpty ? nil : workTree
    }

    /// Runs a query whose `-q` turns "there is no such thing to report"
    /// into a silent exit 1, and reports that answer as nil. Detached HEAD
    /// and unborn HEAD reach their callers this way, so exit 1 here is a
    /// value rather than a failure. Every other exit code still throws.
    private static func runReportingNoAnswerAsNil(
        args: [String],
        workDir: String
    ) async throws -> String? {
        do {
            let output = try await run(args: args, workDir: workDir)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.commandFailed(let exitCode, _, _) where exitCode == 1 {
            return nil
        }
    }

    /// Commit history for an already-resolved repository, skipping the
    /// `rev-parse` that `commitLog(workDir:maxCount:skip:)` needs to
    /// classify the work tree.
    static func commitLog(
        location: GitRepositoryLocation,
        maxCount: Int,
        skip: Int
    ) async throws -> [GitCommit] {
        let format = "%x1f%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%P%x1e"
        var args = ["log"]
        // Linked worktrees share refs, so --all would include sibling branch
        // history. They are the ones whose Git directory sits below the
        // common one.
        if location.gitDirectory == location.gitCommonDirectory {
            args.append("--all")
        }
        args += ["--graph", "--format=\(format)",
                 "--max-count=\(maxCount)", "--skip=\(skip)"]

        let output = try await run(args: args, workDir: location.workTree)
        return parseCommitLog(output)
    }

    static func commitLog(workDir: String, maxCount: Int, skip: Int) async throws -> [GitCommit] {
        let location = try await repositoryLocation(workDir: workDir)
        return try await commitLog(location: location, maxCount: maxCount, skip: skip)
    }

    static func commitFiles(hash: String, workDir: String) async throws -> [CommitFileEntry] {
        guard isValidRef(hash) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "diff-tree")
        }

        // Check if root commit (no parents)
        let parentCheck = try? await run(args: ["rev-parse", "\(hash)^"], workDir: workDir)
        let isRoot = parentCheck == nil

        var args: [String]
        if isRoot {
            args = ["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", hash]
        } else {
            args = ["diff-tree", "--no-commit-id", "-r", "--name-status", "-z", hash]
        }

        let output = try await run(args: args, workDir: workDir)
        return parseCommitFiles(output, commitHash: hash)
    }

    static func fileDiff(source: DiffSource) async throws -> String {
        let args: [String]
        let workDir: String

        switch source {
        case .unstaged(let path, let wd):
            args = ["diff", "--", path]
            workDir = wd
        case .staged(let path, let wd):
            args = ["diff", "--cached", "--", path]
            workDir = wd
        case .commit(let hash, let path, let wd):
            guard isValidRef(hash) else {
                throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "show")
            }
            args = ["show", "--format=", "--patch", hash, "--", path]
            workDir = wd
        case .untracked(let path, let wd):
            return try await untrackedFileDiff(path: path, workDir: wd)
        }

        let output = try await run(args: args, workDir: workDir)

        if output.utf8.count > maxDiffSize {
            let index = output.utf8.index(output.utf8.startIndex, offsetBy: maxDiffSize)
            return String(output[..<index])
        }

        return output
    }

    /// Synthesize a unified diff for an untracked file by reading its content.
    private static func untrackedFileDiff(path: String, workDir: String) async throws -> String {
        let fullPath = (workDir as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: fullPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GitError.commandFailed(exitCode: -1, stderr: "Cannot read file: \(path)", command: "diff")
        }

        // Binary check: look for null bytes in first 8KB
        let checkSize = min(data.count, 8192)
        if data.prefix(checkSize).contains(0) {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        guard var content = String(data: data, encoding: .utf8) else {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        if content.utf8.count > maxDiffSize {
            let idx = content.utf8.index(content.utf8.startIndex, offsetBy: maxDiffSize)
            content = String(content[..<idx])
        }

        let lines = content.components(separatedBy: "\n")
        // Remove trailing empty element from split if file ends with newline
        let effectiveLines = lines.last == "" ? Array(lines.dropLast()) : lines
        let lineCount = effectiveLines.count

        var result = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        result += "@@ -0,0 +1,\(lineCount) @@\n"
        for line in effectiveLines {
            result += "+\(line)\n"
        }
        return result
    }

    // MARK: - Process Execution

    /// Every public entry point above (`repoRoot`, `gitStatus`,
    /// `commitLog`, `commitFiles`, `fileDiff`) drives this with a
    /// read-only git subcommand (`status`, `log`, `diff-tree`, `diff`,
    /// `show`, `rev-parse`) -- there is no write path through here, so
    /// propagating cancellation straight to the subprocess (rather than
    /// the structural-shield treatment `SessionDaemonClient.kill(id:)`
    /// needs for its WRITE op) is safe.
    private static func run(args: [String], workDir: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw GitError.gitNotFound
        }

        let cancellationBridge = ProcessCancellationBridge()
        // Mirrors SystemCommandRunner
        // .runInternal -- withTaskCancellationHandler makes
        // a caller's Task cancellation SIGTERM the spawned `git`
        // process promptly instead of leaving it running until it
        // exits naturally or the unrelated 10s watchdog eventually
        // trips.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: gitPath)
                    process.arguments = args
                    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                    process.environment = [
                        "LC_ALL": "C",
                        "GIT_PAGER": "cat",
                        "GIT_TERMINAL_PROMPT": "0",
                        "GIT_OPTIONAL_LOCKS": "0",
                        "PATH": "/usr/bin:/usr/local/bin",
                        "HOME": NSHomeDirectory(),
                    ]

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    if cancellationBridge.register(process) {
                        // Already cancelled by the time this process
                        // launched; `cancel()` found nothing registered
                        // yet, so terminate it here instead, through the
                        // same terminate-once lock rather than a second,
                        // unsynchronized `process.terminate()` call site.
                        cancellationBridge.terminate()
                    }

                    var didTimeout = false
                    let timeoutItem = DispatchWorkItem {
                        didTimeout = true
                        cancellationBridge.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

                    // Read both pipes concurrently to avoid deadlock
                    var stdoutData = Data()
                    var stderrData = Data()
                    let readGroup = DispatchGroup()
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    readGroup.wait()

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()

                    if didTimeout {
                        let cmd = args.first ?? "unknown"
                        continuation.resume(throwing: GitError.timeout(command: cmd))
                        return
                    }

                    let exitCode = process.terminationStatus
                    if exitCode != 0 {
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        let cmd = args.first ?? "unknown"

                        if stderr.contains("not a git repository") {
                            continuation.resume(throwing: GitError.notARepository)
                            return
                        }
                        if stderr.contains("Permission denied") {
                            continuation.resume(throwing: GitError.permissionDenied(path: workDir))
                            return
                        }

                        continuation.resume(throwing: GitError.commandFailed(exitCode: exitCode, stderr: stderr, command: cmd))
                        return
                    }

                    let result = String(data: stdoutData, encoding: .utf8) ?? ""
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationBridge.cancel()
        }
    }

    // MARK: - Parsers

    static func parseStatus(_ output: String) -> [GitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [GitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0

        while i < parts.count {
            let part = String(parts[i])
            guard !part.isEmpty else { i += 1; continue }

            let firstChar = part.first!

            if firstChar == "?" {
                let path = String(part.dropFirst(2))
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .untracked, isStaged: false, renameScore: nil
                ))
                i += 1
            } else if firstChar == "!" {
                i += 1
            } else if firstChar == "1" {
                let fields = part.split(separator: " ", maxSplits: 8)
                guard fields.count >= 9 else { i += 1; continue }
                let xy = String(fields[1])
                let path = String(fields[8])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                if xChar != "." {
                    if let status = mapStatusChar(xChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: true, renameScore: nil
                        ))
                    }
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
                i += 1
            } else if firstChar == "2" {
                let fields = part.split(separator: " ", maxSplits: 9)
                guard fields.count >= 10 else { i += 1; continue }
                let xy = String(fields[1])
                let scoreField = String(fields[8])
                let path = String(fields[9])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                let scoreChar = scoreField.first ?? "R"
                let score = Int(scoreField.dropFirst())

                var origPath: String? = nil
                if i + 1 < parts.count {
                    origPath = String(parts[i + 1])
                    i += 2
                } else {
                    i += 1
                }

                if xChar != "." {
                    let status: GitFileStatus = scoreChar == "C" ? .copied : .renamed
                    entries.append(GitFileEntry(
                        path: path, origPath: origPath,
                        status: status, isStaged: true, renameScore: score
                    ))
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: origPath,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
            } else if firstChar == "u" {
                let fields = part.split(separator: " ", maxSplits: 10)
                guard fields.count >= 11 else { i += 1; continue }
                let path = String(fields[10])
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .unmerged, isStaged: false, renameScore: nil
                ))
                i += 1
            } else {
                i += 1
            }
        }

        return entries
    }

    /// Maps `git worktree list --porcelain -z` output onto records. Each
    /// NUL-terminated element carries one attribute, label and value split
    /// by a single space, and an empty element ends a record. Lock and
    /// prune reasons are raw strings that may contain spaces and newlines.
    static func parseWorktreeList(_ output: String) -> [GitWorktreeInfo] {
        var infos: [GitWorktreeInfo] = []
        var record = WorktreeRecord()
        var isRecordOpen = false

        for element in output.split(separator: "\0", omittingEmptySubsequences: false) {
            guard !element.isEmpty else {
                if isRecordOpen {
                    if let info = record.info { infos.append(info) }
                    record = WorktreeRecord()
                    isRecordOpen = false
                }
                continue
            }

            let fields = element.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let label = String(fields[0])
            let value = fields.count > 1 ? String(fields[1]) : nil

            guard isRecordOpen else {
                isRecordOpen = true
                // `worktree` opens every record; anything else means this
                // record is not one the schema describes, so it is dropped
                // by leaving `path` unset.
                if label == "worktree" { record.path = value }
                continue
            }
            guard record.path != nil else { continue }

            switch label {
            case "HEAD": record.headOID = value
            case "branch": record.branchRef = value
            case "detached": record.isDetached = true
            case "bare": record.isBare = true
            case "locked":
                record.isLocked = true
                record.lockReason = value
            case "prunable":
                record.isPrunable = true
                record.prunableReason = value
            default: break
            }
        }

        if isRecordOpen, let info = record.info {
            infos.append(info)
        }
        return infos
    }

    private struct WorktreeRecord {
        var path: String?
        var headOID: String?
        var branchRef: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        var info: GitWorktreeInfo? {
            guard let path else { return nil }
            return GitWorktreeInfo(
                path: path,
                headOID: headOID,
                branchRef: branchRef,
                isDetached: isDetached,
                isBare: isBare,
                isLocked: isLocked,
                lockReason: lockReason,
                isPrunable: isPrunable,
                prunableReason: prunableReason
            )
        }
    }

    static func parseCommitLog(_ output: String) -> [GitCommit] {
        guard !output.isEmpty else { return [] }

        var commits: [GitCommit] = []
        let lines = output.components(separatedBy: "\n")
        var accumulatedGraphPrefix = ""
        var accumulatedData = ""

        for line in lines {
            var graphPart = ""
            var dataPart = ""
            var foundData = false

            for char in line {
                if !foundData {
                    if char == "\u{1F}" || char == "\u{1E}" {
                        foundData = true
                        dataPart.append(char)
                    } else if "|*/\\ -_.".contains(char) {
                        graphPart.append(char)
                    } else {
                        graphPart.append(char)
                    }
                } else {
                    dataPart.append(char)
                }
            }

            accumulatedData += dataPart
            if accumulatedGraphPrefix.isEmpty || graphPart.contains("*") {
                accumulatedGraphPrefix = graphPart
            }

            if accumulatedData.contains("\u{1E}") {
                let records = accumulatedData.components(separatedBy: "\u{1E}")
                for record in records {
                    let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let fields = trimmed.components(separatedBy: "\u{1F}")
                    // Fields: ["", hash, shortHash, message, author, relativeDate, parents]
                    // First field is empty because record starts with \x1f
                    guard fields.count >= 6 else { continue }
                    let hash = fields[1]
                    let shortHash = fields[2]
                    let message = fields[3]
                    let author = fields[4]
                    let relativeDate = fields[5]
                    let parentIDsStr = fields.count > 6 ? fields[6] : ""
                    let parentIDs = parentIDsStr.isEmpty ? [] : parentIDsStr.split(separator: " ").map(String.init)

                    commits.append(GitCommit(
                        id: hash,
                        shortHash: shortHash,
                        message: message,
                        author: author,
                        relativeDate: relativeDate,
                        parentIDs: parentIDs,
                        graphPrefix: accumulatedGraphPrefix
                    ))
                }
                accumulatedData = ""
                accumulatedGraphPrefix = ""
            }
        }

        return commits
    }

    static func parseCommitFiles(_ output: String, commitHash: String) -> [CommitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [CommitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < parts.count {
            let part = parts[i]
            guard !part.isEmpty else { i += 1; continue }

            let statusChar = part.first!

            switch statusChar {
            case "M", "A", "D", "T":
                if i + 1 < parts.count {
                    let path = parts[i + 1]
                    if let status = GitFileStatus(rawValue: String(statusChar)) {
                        entries.append(CommitFileEntry(
                            commitHash: commitHash, path: path,
                            origPath: nil, status: status
                        ))
                    }
                    i += 2
                } else {
                    i += 1
                }
            case "R", "C":
                if i + 2 < parts.count {
                    let origPath = parts[i + 1]
                    let newPath = parts[i + 2]
                    let status: GitFileStatus = statusChar == "R" ? .renamed : .copied
                    entries.append(CommitFileEntry(
                        commitHash: commitHash, path: newPath,
                        origPath: origPath, status: status
                    ))
                    i += 3
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }

        return entries
    }

    private static func isValidRef(_ ref: String) -> Bool {
        let pattern = /^[0-9a-fA-F]{4,40}$/
        return ref.wholeMatch(of: pattern) != nil
    }

    private static func mapStatusChar(_ char: Character) -> GitFileStatus? {
        switch char {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: nil
        }
    }
}
