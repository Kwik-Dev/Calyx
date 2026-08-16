// GitRepoDiscovery.swift
// Calyx
//
// Resolves the repositories shown as Changes sidebar sections.

import Foundation

struct GitRepoDiscoveryResult: Equatable, Sendable {
    let sections: [GitRepoDescriptor]
    /// Set only when no section could be built and at least one seed failed
    /// for a reason other than not being a git repository. Empty sections
    /// with no message mean none of the seeds was a repository.
    let failureMessage: String?
}

enum GitRepoDiscovery {
    /// Expands terminal working directories into the full set of sections
    /// to display: every seed's repository plus the other worktrees that
    /// share its Git directory. Bare, prunable, and missing worktrees are
    /// dropped, duplicates collapse by root path, and the result is in the
    /// fixed display order (families by root path, main worktree before
    /// linked worktrees).
    static func discover(seedWorkDirs: [String]) async -> GitRepoDiscoveryResult {
        var seeds: [String] = []
        var seenSeeds: Set<String> = []
        for workDir in seedWorkDirs where seenSeeds.insert(workDir).inserted {
            seeds.append(workDir)
        }
        guard !seeds.isEmpty else {
            return GitRepoDiscoveryResult(sections: [], failureMessage: nil)
        }

        let resolutions = await resolveSeeds(seeds)
        let families = groupIntoFamilies(resolutions.compactMap(\.location))
        let expanded = await expandFamilies(families)

        var sections: [GitRepoDescriptor] = []
        var seenRootPaths: Set<String> = []
        for family in expanded.sorted(by: { $0.sortKey < $1.sortKey }) {
            for descriptor in family.descriptors where seenRootPaths.insert(descriptor.rootPath).inserted {
                sections.append(descriptor)
            }
        }

        // Seeds that are simply not repositories are the normal case for a
        // terminal pane, so only the other failures are worth reporting,
        // and only when they left nothing to show.
        let failureMessage = sections.isEmpty
            ? resolutions.compactMap(\.failureMessage).first
            : nil
        return GitRepoDiscoveryResult(sections: sections, failureMessage: failureMessage)
    }

    /// The section owning `workDir`: the longest `rootPath` that equals it
    /// or is one of its ancestors. Matching is on path components, so
    /// `/a/Calyx` never claims `/a/Calyx-worktrees/x`.
    static func activeRepoID(for workDir: String?, in sections: [GitRepoDescriptor]) -> String? {
        guard let workDir else { return nil }
        let path = GitRepositoryLocation.standardize(workDir)

        var match: String?
        for section in sections {
            let rootPath = section.rootPath
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            if rootPath.count > (match?.count ?? -1) {
                match = rootPath
            }
        }
        return match
    }

    // MARK: - Seeds

    /// One seed's outcome. `failureMessage` stays nil when the seed is
    /// merely outside any repository, which is not a failure to report.
    private struct SeedResolution: Sendable {
        let index: Int
        let location: GitRepositoryLocation?
        let failureMessage: String?
    }

    private static func resolveSeeds(_ seeds: [String]) async -> [SeedResolution] {
        let resolutions = await withTaskGroup(of: SeedResolution.self) { group in
            for (index, workDir) in seeds.enumerated() {
                group.addTask {
                    do {
                        let location = try await GitService.repositoryLocation(workDir: workDir)
                        return SeedResolution(
                            index: index,
                            location: location.standardized,
                            failureMessage: nil
                        )
                    } catch GitService.GitError.notARepository {
                        return SeedResolution(index: index, location: nil, failureMessage: nil)
                    } catch {
                        return SeedResolution(
                            index: index,
                            location: nil,
                            failureMessage: error.localizedDescription
                        )
                    }
                }
            }
            var resolutions: [SeedResolution] = []
            for await resolution in group {
                resolutions.append(resolution)
            }
            return resolutions
        }
        // Child tasks finish in whatever order git answers, while both the
        // reported failure and the dedupe below follow seed order.
        return resolutions.sorted { $0.index < $1.index }
    }

    // MARK: - Families

    /// The worktrees sharing one Git directory, plus the work tree the
    /// `git worktree list` call runs in.
    private struct Family: Sendable {
        let commonDirectory: String
        let seedLocations: [GitRepositoryLocation]

        var listWorkDir: String {
            seedLocations[0].workTree
        }
    }

    private struct FamilySections: Sendable {
        let sortKey: String
        let descriptors: [GitRepoDescriptor]
    }

    private static func groupIntoFamilies(
        _ locations: [GitRepositoryLocation]
    ) -> [Family] {
        var seedsByCommonDirectory: [String: [GitRepositoryLocation]] = [:]
        for location in locations {
            var seeds = seedsByCommonDirectory[location.gitCommonDirectory] ?? []
            if !seeds.contains(where: { $0.workTree == location.workTree }) {
                seeds.append(location)
                seedsByCommonDirectory[location.gitCommonDirectory] = seeds
            }
        }
        return seedsByCommonDirectory
            .map { commonDirectory, seeds in
                Family(
                    commonDirectory: commonDirectory,
                    seedLocations: seeds.sorted { $0.workTree < $1.workTree }
                )
            }
            .sorted { $0.commonDirectory < $1.commonDirectory }
    }

    private static func expandFamilies(_ families: [Family]) async -> [FamilySections] {
        await withTaskGroup(of: FamilySections?.self) { group in
            for family in families {
                group.addTask { await expand(family) }
            }
            var expanded: [FamilySections] = []
            for await sections in group {
                if let sections { expanded.append(sections) }
            }
            return expanded
        }
    }

    private static func expand(_ family: Family) async -> FamilySections? {
        let descriptors: [GitRepoDescriptor]
        if let infos = try? await GitService.worktreeList(workDir: family.listWorkDir) {
            descriptors = await describe(infos)
        } else {
            // Without the list there is still one section per seed: the
            // repositories the seeds resolved to are known to exist.
            descriptors = family.seedLocations.map {
                GitRepoDescriptor(
                    rootPath: $0.workTree,
                    displayName: ($0.workTree as NSString).lastPathComponent,
                    kind: kind(of: $0),
                    branch: nil,
                    headShortHash: nil,
                    location: $0
                )
            }
        }

        let ordered = descriptors.sorted {
            ($0.kind.sortRank, $0.rootPath) < ($1.kind.sortRank, $1.rootPath)
        }
        guard let first = ordered.first else { return nil }
        // The main worktree sorts first when the family has one; a bare
        // family orders by its alphabetically first worktree, because git
        // does not specify the order of the linked worktrees it lists.
        return FamilySections(sortKey: first.rootPath, descriptors: ordered)
    }

    private static func describe(_ infos: [GitWorktreeInfo]) async -> [GitRepoDescriptor] {
        let candidates = infos.filter { info in
            !info.isBare
                && !info.isPrunable
                && FileManager.default.fileExists(atPath: info.path)
        }

        return await withTaskGroup(of: GitRepoDescriptor?.self) { group in
            for info in candidates {
                group.addTask {
                    guard let location = try? await GitService.repositoryLocation(workDir: info.path) else {
                        return nil
                    }
                    let standardized = location.standardized
                    return GitRepoDescriptor(
                        rootPath: standardized.workTree,
                        displayName: (standardized.workTree as NSString).lastPathComponent,
                        kind: kind(of: standardized),
                        branch: info.branchRef.map(branchName(fromRef:)),
                        headShortHash: info.headOID.map { String($0.prefix(shortHashLength)) },
                        location: standardized
                    )
                }
            }
            var descriptors: [GitRepoDescriptor] = []
            for await descriptor in group {
                if let descriptor { descriptors.append(descriptor) }
            }
            return descriptors
        }
    }

    private static let shortHashLength = 7

    private static func kind(of location: GitRepositoryLocation) -> GitRepoKind {
        // A linked worktree has its own Git directory below the shared one.
        location.gitDirectory == location.gitCommonDirectory ? .repository : .worktree
    }

    private static func branchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }
}

private extension GitRepoKind {
    /// Position within a family: the repository itself, then its linked
    /// worktrees, then its submodules.
    var sortRank: Int {
        switch self {
        case .repository: 0
        case .worktree: 1
        case .submodule: 2
        }
    }
}
