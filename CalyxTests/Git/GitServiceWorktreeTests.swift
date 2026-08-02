// GitServiceWorktreeTests.swift
// CalyxTests
//
// Integration tests for commit history scoping across Git worktrees.

import Foundation
import Testing
@testable import Calyx

struct GitServiceWorktreeTests {
    @Test func test_linkedWorktree_commitLogExcludesSiblingBranchCommits() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let sourceRepository = scratchDirectory.appendingPathComponent("source")
        try runGit(["init", "-q", "-b", "main", sourceRepository.path], in: scratchDirectory)
        let baseCommit = try commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: sourceRepository
        )

        let bareRepository = scratchDirectory.appendingPathComponent("shared.git")
        try runGit(["clone", "-q", "--bare", sourceRepository.path, bareRepository.path], in: scratchDirectory)

        let currentWorktree = scratchDirectory.appendingPathComponent("current-worktree")
        let siblingWorktree = scratchDirectory.appendingPathComponent("sibling-worktree")
        try runGit(
            ["--git-dir=\(bareRepository.path)", "worktree", "add", "-q", currentWorktree.path, "main"],
            in: scratchDirectory
        )
        try runGit(
            ["--git-dir=\(bareRepository.path)", "worktree", "add", "-q", "-b", "sibling", siblingWorktree.path, "main"],
            in: scratchDirectory
        )

        let siblingCommit = try commit(
            file: "sibling.txt",
            contents: "sibling only\n",
            message: "sibling-only commit",
            in: siblingWorktree
        )

        let commits = try await GitService.commitLog(
            workDir: currentWorktree.path,
            maxCount: 100,
            skip: 0
        )
        let commitIDs = Set(commits.map(\.id))

        #expect(commitIDs.contains(baseCommit))
        #expect(!commitIDs.contains(siblingCommit))
    }

    @Test func test_standardRepository_commitLogIncludesAllBranches() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let repository = scratchDirectory.appendingPathComponent("repository")
        try runGit(["init", "-q", "-b", "main", repository.path], in: scratchDirectory)
        let baseCommit = try commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: repository
        )

        try runGit(["checkout", "-q", "-b", "sibling"], in: repository)
        let siblingCommit = try commit(
            file: "sibling.txt",
            contents: "sibling only\n",
            message: "sibling-only commit",
            in: repository
        )
        try runGit(["checkout", "-q", "main"], in: repository)

        let commits = try await GitService.commitLog(
            workDir: repository.path,
            maxCount: 100,
            skip: 0
        )
        let commitIDs = Set(commits.map(\.id))

        #expect(commitIDs.contains(baseCommit))
        #expect(commitIDs.contains(siblingCommit))
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitServiceWorktreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func runGit(_ arguments: [String], in workDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.environment = [
            "GIT_AUTHOR_EMAIL": "calyx-tests@example.invalid",
            "GIT_AUTHOR_NAME": "Calyx Tests",
            "GIT_COMMITTER_EMAIL": "calyx-tests@example.invalid",
            "GIT_COMMITTER_NAME": "Calyx Tests",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw GitFixtureError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(
        file: String,
        contents: String,
        message: String,
        in repository: URL
    ) throws -> String {
        try contents.write(
            to: repository.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", file], in: repository)
        try runGit(["commit", "-q", "-m", message], in: repository)
        return try runGit(["rev-parse", "HEAD"], in: repository)
    }
}

private struct GitFixtureError: Error, CustomStringConvertible {
    let arguments: [String]
    let exitCode: Int32
    let stderr: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed (exit \(exitCode)): \(stderr)"
    }
}
