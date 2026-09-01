// GitServiceRefListTests.swift
// CalyxTests
//
// GitService.refList: every local branch, remote branch, and tag a
// repository has, classified by kind and shortened the way git itself
// shortens them -- with the `origin/HEAD` symref excluded, since it is
// not a ref a user picks, it is a pointer to one.

import Foundation
import Testing
@testable import Calyx

struct GitServiceRefListTests {
    @Test func test_refList_classifiesLocalBranchesRemoteBranchesAndTags() async throws {
        let scratch = try GitScratch.makeDirectory("reflist")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)
        try GitScratch.run(["tag", "v1.0"], in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.refList(location: location)

        #expect(refs.contains(GitRefInfo(fullName: "refs/heads/main", shortName: "main", kind: .localBranch)))
        #expect(refs.contains(GitRefInfo(fullName: "refs/remotes/origin/main", shortName: "origin/main", kind: .remoteBranch)))
        #expect(refs.contains(GitRefInfo(fullName: "refs/tags/v1.0", shortName: "v1.0", kind: .tag)))
        #expect(!refs.map(\.fullName).contains("refs/remotes/origin/HEAD"))
    }

    @Test func test_refList_excludesOriginHeadSymrefFromRemoteBranches() async throws {
        let scratch = try GitScratch.makeDirectory("reflist-symref")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.refList(location: location)

        let remoteBranches = refs.filter { $0.kind == .remoteBranch }
        #expect(remoteBranches.map(\.shortName) == ["origin/main"])
    }

    @Test func test_refList_isEmptyForUnbornRepository() async throws {
        let scratch = try GitScratch.makeDirectory("reflist-unborn")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let refs = try await GitService.refList(location: location)

        #expect(refs.isEmpty)
    }
}
