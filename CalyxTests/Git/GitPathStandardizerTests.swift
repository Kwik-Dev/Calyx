// GitPathStandardizerTests.swift
// CalyxTests
//
// Holding on to the file system's spelling of a directory: the same
// answers, read once each.

import Foundation
import Testing
@testable import Calyx

struct GitPathStandardizerTests {
    @Test func aDirectoryIsResolvedOnceHoweverOftenItIsAskedFor() {
        var reads: [String] = []
        let standardizer = GitPathStandardizer { path in
            reads.append(path)
            return path + "/resolved"
        }

        #expect(standardizer.standardize("/a") == "/a/resolved")
        #expect(standardizer.standardize("/a") == "/a/resolved")
        #expect(standardizer.standardize("/b") == "/b/resolved")
        #expect(standardizer.standardize("/a") == "/a/resolved")

        #expect(reads == ["/a", "/b"])
    }

    @Test func aForgottenDirectoryIsResolvedAgainWhenItComesBack() {
        var reads: [String] = []
        let standardizer = GitPathStandardizer { path in
            reads.append(path)
            return path + "/resolved"
        }

        _ = standardizer.standardize("/a")
        _ = standardizer.standardize("/b")
        standardizer.keepOnly(["/a"])
        _ = standardizer.standardize("/a")
        _ = standardizer.standardize("/b")

        #expect(reads == ["/a", "/b", "/b"])
    }

    @Test func rememberedSpellingsAreTheOnesTheFileSystemGives() throws {
        let scratch = try GitScratch.makeDirectory("standardizer-symlink")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let real = scratch.appendingPathComponent("real")
        let nested = real.appendingPathComponent("Proj/sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // What the shell reports for a pane opened through the symlink.
        let linked = link.appendingPathComponent("Proj/sub").path
        let resolved = GitRepositoryLocation.standardize(linked)
        try #require(resolved != linked)

        let standardizer = GitPathStandardizer()
        #expect(standardizer.standardize(linked) == resolved)
        #expect(standardizer.standardize(linked) == resolved)

        // The same answers reaching the rules that compare panes to sections.
        let sections = [repository(at: GitRepositoryLocation.standardize(
            real.appendingPathComponent("Proj").path
        ))]
        let owner = sections[0].rootPath
        #expect(GitRepoDiscovery.activeRepoID(for: linked, in: sections) == owner)
        #expect(
            GitRepoDiscovery.activeRepoID(for: linked, in: sections, standardizer: standardizer)
                == owner
        )
        #expect(
            GitRepoDiscovery.coverage(of: [linked], in: sections, standardizer: standardizer)
                == GitRepoDiscovery.coverage(of: [linked], in: sections)
        )

        let outside = link.appendingPathComponent("elsewhere").path
        #expect(
            GitRepoDiscovery.coverage(of: [outside], in: sections, standardizer: standardizer)
                == GitRepoDiscovery.coverage(of: [outside], in: sections)
        )
    }
}

private func repository(at rootPath: String) -> GitRepoDescriptor {
    GitRepoDescriptor(
        rootPath: rootPath,
        displayName: (rootPath as NSString).lastPathComponent,
        kind: .repository,
        branch: "main",
        headShortHash: "0123456",
        location: GitRepositoryLocation(
            workTree: rootPath,
            gitDirectory: rootPath + "/.git",
            gitCommonDirectory: rootPath + "/.git"
        )
    )
}
