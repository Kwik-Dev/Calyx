// GitServiceAutoRefsTests.swift
// CalyxTests
//
// GitService.autoRefs resolves the VSCode-equivalent "Auto" starting
// point: HEAD, then its upstream, then the upstream's remote's default
// branch (its `<remote>/HEAD` symref) -- each included only once and
// only when it adds a ref the earlier ones did not already name.

import Foundation
import Testing
@testable import Calyx

struct GitServiceAutoRefsTests {
    @Test func test_autoRefs_clonedRepository_upstreamEqualsBase_yieldsHeadAndUpstreamOnly() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-clone")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/main", "refs/remotes/origin/main"])
    }

    @Test func test_autoRefs_localOnlyBranchWithNoUpstream_yieldsHeadOnly() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-local")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/main"])
    }

    @Test func test_autoRefs_detachedHead_yieldsHeadLiteral() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-detached")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        let baseCommit = try GitScratch.commit(
            file: "base.txt", contents: "base\n", message: "base commit", in: repository
        )
        try GitScratch.run(["checkout", "-q", "--detach", baseCommit], in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["HEAD"])
    }

    @Test func test_autoRefs_unbornRepository_yieldsNoRefs() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-unborn")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs.isEmpty)
    }

    @Test func test_autoRefs_upstreamDiffersFromRemoteDefaultBranch_yieldsAllThree() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-differing-base")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)
        try GitScratch.run(["checkout", "-q", "-b", "feature"], in: source)
        try GitScratch.commit(file: "feature.txt", contents: "feature\n", message: "feature commit", in: source)
        try GitScratch.run(["checkout", "-q", "main"], in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)
        try GitScratch.run(["checkout", "-q", "-b", "feature", "--track", "origin/feature"], in: clone)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/feature", "refs/remotes/origin/feature", "refs/remotes/origin/main"])
    }

    @Test func test_autoRefs_originHeadUnset_omitsBase() async throws {
        let scratch = try GitScratch.makeDirectory("autorefs-no-origin-head")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)
        try GitScratch.run(["checkout", "-q", "-b", "feature"], in: source)
        try GitScratch.commit(file: "feature.txt", contents: "feature\n", message: "feature commit", in: source)
        try GitScratch.run(["checkout", "-q", "main"], in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)
        try GitScratch.run(["checkout", "-q", "-b", "feature", "--track", "origin/feature"], in: clone)
        try GitScratch.run(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"], in: clone)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/feature", "refs/remotes/origin/feature"])
    }

    @Test func test_autoRefs_upstreamConfiguredButRemoteTrackingRefDeleted_excludesUpstream() async throws {
        // `git fetch --prune` equivalent: branch.<name>.merge/.remote still
        // point at origin/main, but the remote-tracking ref itself is gone.
        // `for-each-ref --format=%(upstream)` reads that config regardless,
        // so autoRefs must cross-check against refList's live refs rather
        // than trusting the name it gets back.
        let scratch = try GitScratch.makeDirectory("autorefs-pruned-upstream")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)
        try GitScratch.run(["update-ref", "-d", "refs/remotes/origin/main"], in: clone)

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/main"])
        #expect(!refs.contains("refs/remotes/origin/main"))
    }

    @Test func test_autoRefs_originHeadIsDanglingSymref_omitsBase() async throws {
        // origin/HEAD is a symbolic ref; `symbolic-ref -q` happily reports
        // its target text even when that target does not itself exist as a
        // ref. autoRefs must validate the target against refList before
        // adding it, the same way it validates upstream.
        let scratch = try GitScratch.makeDirectory("autorefs-dangling-origin-head")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: source)

        let clone = scratch.appendingPathComponent("clone")
        try GitScratch.run(["clone", "-q", source.path, clone.path], in: scratch)
        try GitScratch.run(
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone"],
            in: clone
        )

        let location = try await GitService.repositoryLocation(workDir: clone.path)
        let refs = try await GitService.autoRefs(location: location)

        #expect(refs == ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(!refs.contains("refs/remotes/origin/gone"))
    }
}
