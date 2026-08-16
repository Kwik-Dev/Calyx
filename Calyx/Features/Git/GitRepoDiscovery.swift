// GitRepoDiscovery.swift
// Calyx
//
// Resolves the repositories shown as Changes sidebar sections.

import Foundation

struct GitRepoDiscoveryResult: Equatable, Sendable {
    let sections: [GitRepoDescriptor]
    /// What the run could not check. A displayed section these cover was
    /// not looked at, so its absence from `sections` is not evidence that
    /// it is gone.
    let gaps: GitRepoDiscoveryGaps
    /// Set only when no section could be built and at least one seed failed
    /// for a reason other than not being a git repository. Empty sections
    /// with no message mean none of the seeds was a repository.
    let failureMessage: String?
}

/// The parts of the file system a discovery run could not read, each with
/// the failure that stopped it. Separating "not checked" from "not there"
/// is what keeps a repository that answered late, or not at all, from
/// disappearing out of the sidebar.
struct GitRepoDiscoveryGaps: Equatable, Sendable {
    /// Directories whose repository could not be resolved.
    var workDirs: [String: String] = [:]
    /// Git common directories whose worktree list could not be read, which
    /// leaves every worktree of that repository unconfirmed.
    var commonDirectories: [String: String] = [:]

    /// Why the run could not check `descriptor`, or `nil` when it did.
    func message(for descriptor: GitRepoDescriptor) -> String? {
        if let message = commonDirectories[descriptor.location.gitCommonDirectory] {
            return message
        }
        let root = descriptor.rootPath
        for workDir in workDirs.keys.sorted()
        where workDir == root || workDir.hasPrefix(root + "/") {
            return workDirs[workDir]
        }
        return nil
    }

    mutating func formUnion(_ other: GitRepoDiscoveryGaps) {
        workDirs.merge(other.workDirs) { existing, _ in existing }
        commonDirectories.merge(other.commonDirectories) { existing, _ in existing }
    }
}

/// Remembers the file system's own spelling of the paths it has resolved.
/// Reading that spelling is a file system access, a shell reports its
/// working directory on every prompt, and every pane's directory is
/// resolved on each of those reports, so the same directories would
/// otherwise be read over and over for an answer that only changes when a
/// pane moves. `keepOnly` bounds what is held to the directories in use.
final class GitPathStandardizer {
    private let resolve: (String) -> String
    private var spellings: [String: String] = [:]

    init(resolve: @escaping (String) -> String = GitRepositoryLocation.standardize) {
        self.resolve = resolve
    }

    func standardize(_ path: String) -> String {
        if let known = spellings[path] { return known }
        let spelling = resolve(path)
        spellings[path] = spelling
        return spelling
    }

    /// Forgets every path outside `paths`, which are resolved again if they
    /// are ever asked for once more.
    func keepOnly(_ paths: Set<String>) {
        spellings = spellings.filter { paths.contains($0.key) }
    }
}

/// How the displayed sections account for the terminal panes' directories.
/// Discovery is what turns a directory no section covers into a section, so
/// a change in either half is a change only discovery can resolve: a new
/// repository on one side, the last pane leaving a repository on the other.
struct GitSeedCoverage: Equatable, Sendable {
    var ownerRepoIDs: Set<String> = []
    var uncoveredWorkDirs: Set<String> = []
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
            return GitRepoDiscoveryResult(sections: [], gaps: GitRepoDiscoveryGaps(), failureMessage: nil)
        }

        let resolutions = await resolveSeeds(seeds)
        var gaps = GitRepoDiscoveryGaps()
        for resolution in resolutions {
            guard let failureMessage = resolution.failureMessage else { continue }
            gaps.workDirs[GitRepositoryLocation.standardize(resolution.workDir)] = failureMessage
        }

        let families = groupIntoFamilies(resolutions.compactMap(\.location))
        let expanded = await expandFamilies(families)
        for expansion in expanded {
            gaps.formUnion(expansion.gaps)
        }

        let sections = ordered(expanded.flatMap(\.descriptors))
        // Seeds that are simply not repositories are the normal case for a
        // terminal pane, so only the other failures are worth reporting,
        // and only when they left nothing to show.
        let failureMessage = sections.isEmpty
            ? resolutions.compactMap(\.failureMessage).first
            : nil
        return GitRepoDiscoveryResult(sections: sections, gaps: gaps, failureMessage: failureMessage)
    }

    /// What to display after a run: everything it confirmed, plus the
    /// displayed sections it could not check, in the fixed order. A section
    /// is dropped only by a run that looked where it lives and did not find
    /// it there.
    static func merge(
        discovered: [GitRepoDescriptor],
        keeping displayed: [GitRepoDescriptor],
        gaps: GitRepoDiscoveryGaps
    ) -> [GitRepoDescriptor] {
        let discoveredIDs = Set(discovered.map(\.id))
        let unchecked = displayed.filter {
            !discoveredIDs.contains($0.id) && gaps.message(for: $0) != nil
        }
        return ordered(discovered + unchecked)
    }

    /// The fixed display order: repositories sharing a Git directory stay
    /// together, ordered by the root path of their first section, and
    /// within one of those families the repository itself comes before its
    /// linked worktrees and those before its submodules. Duplicate root
    /// paths collapse onto their first occurrence.
    static func ordered(_ descriptors: [GitRepoDescriptor]) -> [GitRepoDescriptor] {
        var byCommonDirectory: [String: [GitRepoDescriptor]] = [:]
        var seenRootPaths: Set<String> = []
        for descriptor in descriptors where seenRootPaths.insert(descriptor.rootPath).inserted {
            byCommonDirectory[descriptor.location.gitCommonDirectory, default: []].append(descriptor)
        }

        let families: [(sortKey: String, descriptors: [GitRepoDescriptor])] =
            byCommonDirectory.values.compactMap { family in
                let sorted = family.sorted {
                    ($0.kind.sortRank, $0.rootPath) < ($1.kind.sortRank, $1.rootPath)
                }
                // The main worktree sorts first when the family has one; a
                // bare family orders by its alphabetically first worktree,
                // because git does not specify the order it lists them in.
                guard let first = sorted.first else { return nil }
                return (first.rootPath, sorted)
            }
        return families.sorted { $0.sortKey < $1.sortKey }.flatMap(\.descriptors)
    }

    /// The section owning `workDir`: the longest `rootPath` that equals it
    /// or is one of its ancestors. Matching is on path components, so
    /// `/a/Calyx` never claims `/a/Calyx-worktrees/x`. `standardizer` is
    /// how the caller's repeated questions about the same directories are
    /// answered without reading the file system again; the default one is
    /// empty, which resolves every path it is given.
    static func activeRepoID(
        for workDir: String?,
        in sections: [GitRepoDescriptor],
        standardizer: GitPathStandardizer = GitPathStandardizer()
    ) -> String? {
        guard let workDir else { return nil }
        let path = standardizer.standardize(workDir)

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

    /// Which sections own `workDirs` and which of them no section covers.
    /// Two runs of this that agree mean the panes are still inside the same
    /// repositories, whatever subdirectory they moved to.
    static func coverage(
        of workDirs: [String],
        in sections: [GitRepoDescriptor],
        standardizer: GitPathStandardizer = GitPathStandardizer()
    ) -> GitSeedCoverage {
        var coverage = GitSeedCoverage()
        for workDir in workDirs {
            if let owner = activeRepoID(for: workDir, in: sections, standardizer: standardizer) {
                coverage.ownerRepoIDs.insert(owner)
            } else {
                coverage.uncoveredWorkDirs.insert(standardizer.standardize(workDir))
            }
        }
        return coverage
    }

    // MARK: - Seeds

    /// One seed's outcome. `failureMessage` stays nil when the seed is
    /// merely outside any repository, which is not a failure to report.
    private struct SeedResolution: Sendable {
        let index: Int
        let workDir: String
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
                            workDir: workDir,
                            location: location.standardized,
                            failureMessage: nil
                        )
                    } catch GitService.GitError.notARepository {
                        return SeedResolution(
                            index: index,
                            workDir: workDir,
                            location: nil,
                            failureMessage: nil
                        )
                    } catch {
                        return SeedResolution(
                            index: index,
                            workDir: workDir,
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

    private struct FamilyExpansion: Sendable {
        let descriptors: [GitRepoDescriptor]
        let gaps: GitRepoDiscoveryGaps
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

    private static func expandFamilies(_ families: [Family]) async -> [FamilyExpansion] {
        await withTaskGroup(of: FamilyExpansion.self) { group in
            for family in families {
                group.addTask { await expand(family) }
            }
            var expanded: [FamilyExpansion] = []
            for await expansion in group {
                expanded.append(expansion)
            }
            return expanded
        }
    }

    private static func expand(_ family: Family) async -> FamilyExpansion {
        var listed: [GitRepoDescriptor] = []
        var gaps = GitRepoDiscoveryGaps()
        do {
            let infos = try await GitService.worktreeList(workDir: family.listWorkDir)
            let described = await describe(infos)
            listed = described.descriptors
            gaps = described.gaps
        } catch {
            // Without the list, the worktrees of this repository other than
            // the seeds cannot be confirmed either way.
            gaps.commonDirectories[family.commonDirectory] = error.localizedDescription
        }

        // The seeds resolved to repositories that exist, so they are
        // sections whether or not the list mentions them. A worktree that
        // has been moved is listed at the path it no longer occupies.
        let listedRootPaths = Set(listed.map(\.rootPath))
        let seeds = family.seedLocations
            .filter { !listedRootPaths.contains($0.workTree) }
            .map { location in
                GitRepoDescriptor(
                    rootPath: location.workTree,
                    displayName: (location.workTree as NSString).lastPathComponent,
                    kind: kind(of: location),
                    branch: nil,
                    headShortHash: nil,
                    location: location
                )
            }
        return FamilyExpansion(descriptors: listed + seeds, gaps: gaps)
    }

    private struct DescribedWorktrees: Sendable {
        let descriptors: [GitRepoDescriptor]
        let gaps: GitRepoDiscoveryGaps
    }

    private enum WorktreeOutcome: Sendable {
        case described(GitRepoDescriptor)
        case unverified(workDir: String, message: String)
    }

    private static func describe(_ infos: [GitWorktreeInfo]) async -> DescribedWorktrees {
        let candidates = infos.filter { info in
            !info.isBare
                && !info.isPrunable
                && FileManager.default.fileExists(atPath: info.path)
        }

        return await withTaskGroup(of: WorktreeOutcome.self) { group in
            for info in candidates {
                group.addTask {
                    let location: GitRepositoryLocation
                    do {
                        location = try await GitService.repositoryLocation(workDir: info.path)
                    } catch {
                        return .unverified(
                            workDir: GitRepositoryLocation.standardize(info.path),
                            message: error.localizedDescription
                        )
                    }
                    let standardized = location.standardized
                    return .described(
                        GitRepoDescriptor(
                            rootPath: standardized.workTree,
                            displayName: (standardized.workTree as NSString).lastPathComponent,
                            kind: kind(of: standardized),
                            branch: info.branchRef.map(branchName(fromRef:)),
                            headShortHash: info.headOID.map { String($0.prefix(shortHashLength)) },
                            location: standardized
                        )
                    )
                }
            }
            var descriptors: [GitRepoDescriptor] = []
            var gaps = GitRepoDiscoveryGaps()
            for await outcome in group {
                switch outcome {
                case .described(let descriptor):
                    descriptors.append(descriptor)
                case .unverified(let workDir, let message):
                    gaps.workDirs[workDir] = message
                }
            }
            return DescribedWorktrees(descriptors: descriptors, gaps: gaps)
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
