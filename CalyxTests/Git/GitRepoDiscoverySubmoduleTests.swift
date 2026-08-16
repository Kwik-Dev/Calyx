// GitRepoDiscoverySubmoduleTests.swift
// CalyxTests
//
// Submodules as Changes sidebar sections: the ones a superproject has
// filled in, and the superproject a pane inside a submodule belongs to.

import Foundation
import Testing
@testable import Calyx

struct GitRepoDiscoverySubmoduleTests {

    @Test func test_discover_addsAPopulatedSubmoduleAfterItsSuperproject() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("discover-submodule")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let submoduleCommit = try GitScratch.run(["rev-parse", "HEAD"], in: fixture.submodule)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [fixture.root.path])

        #expect(result.sections.map(\.rootPath) == [fixture.root.path, fixture.submodule.path])
        #expect(result.sections.map(\.kind) == [.repository, .submodule])
        #expect(result.sections.map(\.displayName) == ["proj", "sub"])
        #expect(result.failureMessage == nil)

        let section = try #require(
            result.sections.first { $0.rootPath == fixture.submodule.path }
        )
        #expect(section.branch == "main")
        let shortHash = try #require(section.headShortHash)
        #expect(submoduleCommit.hasPrefix(shortHash))
        #expect(shortHash.count >= 7)
    }

    @Test func test_discover_buildsTheSuperprojectFamilyFromASubmoduleSeed() async throws {
        let scratch = try GitScratch.makeDirectory("discover-superproject-seed")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try GitSubmoduleScratch.makeRepository("source", in: scratch)
        let superproject = try GitSubmoduleScratch.makeRepository("zeta-main", in: scratch)
        let submodule = try GitSubmoduleScratch.addSubmodule(from: source, at: "sub", in: superproject)
        let worktree = scratch.appendingPathComponent("alpha-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "alpha", worktree.path], in: superproject)

        // The only pane sits inside the submodule, which is how a window
        // opened straight into a submodule looks.
        let result = await GitRepoDiscovery.discover(seedWorkDirs: [submodule.path])

        #expect(result.sections.map(\.rootPath) == [
            superproject.path, worktree.path, submodule.path,
        ])
        #expect(result.sections.map(\.kind) == [.repository, .worktree, .submodule])
    }

    @Test func test_discover_foldsASubmoduleSeedIntoItsSuperprojectFamily() async throws {
        let scratch = try GitScratch.makeDirectory("discover-submodule-seeds")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try GitSubmoduleScratch.makeRepository("source", in: scratch)
        let superproject = try GitSubmoduleScratch.makeRepository("proj", in: scratch)
        let submodule = try GitSubmoduleScratch.addSubmodule(from: source, at: "sub", in: superproject)
        // Sorts between the superproject and its submodule, so a submodule
        // left standing as a family of its own would show up after it.
        let sibling = try GitSubmoduleScratch.makeRepository("proj-tools", in: scratch)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [
            superproject.path, submodule.path, sibling.path,
        ])
        let shuffled = await GitRepoDiscovery.discover(seedWorkDirs: [
            sibling.path, submodule.path, superproject.path,
        ])

        #expect(result.sections.map(\.rootPath) == [
            superproject.path, submodule.path, sibling.path,
        ])
        #expect(result.sections.map(\.kind) == [.repository, .submodule, .repository])
        #expect(shuffled.sections.map(\.rootPath) == result.sections.map(\.rootPath))
        #expect(shuffled.sections.map(\.kind) == result.sections.map(\.kind))
    }

    @Test func test_discover_skipsASubmoduleWhoseDirectoryIsEmpty() async throws {
        let scratch = try GitScratch.makeDirectory("discover-submodule-deinit")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let keptSource = try GitSubmoduleScratch.makeRepository("source-kept", in: scratch)
        let goneSource = try GitSubmoduleScratch.makeRepository("source-gone", in: scratch)
        let superproject = try GitSubmoduleScratch.makeRepository("proj", in: scratch)
        let kept = try GitSubmoduleScratch.addSubmodule(from: keptSource, at: "kept", in: superproject)
        try GitSubmoduleScratch.addSubmodule(from: goneSource, at: "gone", in: superproject)

        // Deinitializing keeps the gitlink in the index and leaves nothing
        // behind to open, which is also the state of a fresh clone.
        try GitScratch.run(["submodule", "deinit", "-f", "--", "gone"], in: superproject)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [superproject.path])

        #expect(result.sections.map(\.rootPath) == [superproject.path, kept.path])
        #expect(result.sections.map(\.kind) == [.repository, .submodule])
    }

    @Test func test_discover_stopsWalkingUpAfterEightSuperprojects() async throws {
        let scratch = try GitScratch.makeDirectory("discover-superproject-depth")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var levels = [try GitSubmoduleScratch.makeRepository("level-0", in: scratch)]
        for level in 1...9 {
            let source = try GitSubmoduleScratch.makeRepository("source-\(level)", in: scratch)
            levels.append(
                try GitSubmoduleScratch.addSubmodule(from: source, at: "sub", in: levels[level - 1])
            )
        }

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [levels[9].path])

        // The walk up stops after eight superprojects, so the ninth one
        // above the seed is not a section and the one below it heads the
        // sections as a repository of its own.
        #expect(result.sections.map(\.rootPath) == levels[1...].map(\.path))
        let expectedKinds = [GitRepoKind.repository] + [GitRepoKind](repeating: .submodule, count: 8)
        #expect(result.sections.map(\.kind) == expectedKinds)
    }

    // MARK: - What a run could not check

    @Test func test_merge_keepsASubmoduleWhoseSuperprojectCouldNotBeListed() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("merge-submodule-unlisted")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let displayed = await GitRepoDiscovery.discover(seedWorkDirs: [fixture.root.path]).sections
        try #require(displayed.map(\.rootPath) == [fixture.root.path, fixture.submodule.path])
        let superproject = try #require(displayed.first { $0.rootPath == fixture.root.path })

        // The `git ls-files` that would have enumerated the submodules runs
        // in the work tree holding them, so its failure is recorded against
        // that work tree and leaves them unchecked.
        let merged = GitRepoDiscovery.merge(
            discovered: [superproject],
            keeping: displayed,
            gaps: GitRepoDiscoveryGaps(workDirs: [superproject.rootPath: "git is busy"])
        )

        #expect(merged.map(\.rootPath) == displayed.map(\.rootPath))
    }

    @Test func test_merge_keepsALinkedWorktreesSubmoduleWhenTheWorktreeListFailed() async throws {
        let scratch = try GitScratch.makeDirectory("merge-worktree-submodule")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try GitSubmoduleScratch.makeRepository("source", in: scratch)
        let main = try GitSubmoduleScratch.makeRepository("zeta-main", in: scratch)
        let mainSubmodule = try GitSubmoduleScratch.addSubmodule(from: source, at: "sub", in: main)
        let worktree = scratch.appendingPathComponent("alpha-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "alpha", worktree.path], in: main)
        // `worktree add` leaves the submodule directory empty, so filling it
        // in is what gives the linked worktree a submodule of its own.
        try GitScratch.run(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            in: worktree
        )
        let worktreeSubmodule = worktree.appendingPathComponent("sub")

        let displayed = await GitRepoDiscovery.discover(seedWorkDirs: [main.path]).sections
        try #require(displayed.map(\.rootPath) == [
            main.path, worktree.path, worktreeSubmodule.path, mainSubmodule.path,
        ])
        let mainSection = try #require(displayed.first { $0.rootPath == main.path })
        let submoduleSection = try #require(
            displayed.first { $0.rootPath == worktreeSubmodule.path }
        )
        // A submodule keeps its Git directory below the work tree that
        // checked it out, so it never shares the family's common directory.
        try #require(
            submoduleSection.location.gitCommonDirectory
                != mainSection.location.gitCommonDirectory
        )

        // Without `git worktree list` only the seed and the submodules of
        // the seed are discovered, and the failure is recorded against the
        // common directory the list would have covered.
        let merged = GitRepoDiscovery.merge(
            discovered: displayed.filter {
                $0.rootPath == main.path || $0.rootPath == mainSubmodule.path
            },
            keeping: displayed,
            gaps: GitRepoDiscoveryGaps(
                commonDirectories: [
                    mainSection.location.gitCommonDirectory: "worktree list failed"
                ]
            )
        )

        #expect(merged.map(\.rootPath) == displayed.map(\.rootPath))
    }
}
