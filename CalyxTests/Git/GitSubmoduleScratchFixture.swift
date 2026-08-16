// GitSubmoduleScratchFixture.swift
// CalyxTests
//
// Builds throwaway superprojects with real submodules.

import Foundation

enum GitSubmoduleScratch {
    /// A superproject with one populated submodule, plus the standalone
    /// repository that submodule was cloned from.
    struct Superproject {
        let scratch: URL
        /// The repository added as a submodule, outside the superproject.
        let source: URL
        /// The superproject's work-tree root.
        let root: URL
        /// The submodule's work tree, inside `root`.
        let submodule: URL
    }

    static func makeSuperproject(
        _ label: String,
        submodulePath: String = "sub"
    ) throws -> Superproject {
        let scratch = try GitScratch.makeDirectory(label)
        let source = try makeRepository("source", in: scratch)
        let root = try makeRepository("proj", in: scratch)
        let submodule = try addSubmodule(from: source, at: submodulePath, in: root)
        return Superproject(scratch: scratch, source: source, root: root, submodule: submodule)
    }

    /// A repository with one commit on `main`, ready to be added as a
    /// submodule somewhere.
    @discardableResult
    static func makeRepository(_ name: String, in directory: URL) throws -> URL {
        let repository = directory.appendingPathComponent(name)
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: directory)
        try GitScratch.commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: repository
        )
        return repository
    }

    /// Adds `source` as a submodule of `superproject` at `path` and commits
    /// the gitlink. Git refuses file-protocol submodule URLs unless asked,
    /// which is what keeps the clone local instead of reaching a network.
    @discardableResult
    static func addSubmodule(
        from source: URL,
        at path: String,
        in superproject: URL
    ) throws -> URL {
        try GitScratch.run(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, path],
            in: superproject
        )
        try GitScratch.run(["commit", "-q", "-m", "add submodule"], in: superproject)
        // `path` carries its own separators, which URL would escape into a
        // single component.
        return URL(fileURLWithPath: (superproject.path as NSString).appendingPathComponent(path))
    }
}
