//
//  SemanticVersion.swift
//  Mousecape
//
//  Semantic-version parsing and ordering (semver.org 2.0 precedence rules) used by
//  the self-updater to compare a GitHub release tag with CFBundleShortVersionString.
//  Pure value type, Foundation only — unit-tested by Tools/UpdaterTests.
//

import Foundation

struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers ("1.4.2-click-assist" -> ["click-assist"]).
    /// A version WITH pre-release identifiers sorts BEFORE the same version without.
    let prerelease: [String]

    init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses "1", "1.4", "1.4.2", "v1.4.2", "V1.4.2-beta.1", "1.4.2+build.7".
    /// Missing minor/patch default to 0; build metadata is ignored (semver rule 10).
    /// Returns nil for anything that is not a version (empty, non-numeric core,
    /// more than three core components, empty pre-release identifier).
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" {
            text.removeFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }

        var prereleaseIDs: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let tail = text[text.index(after: dash)...]
            prereleaseIDs = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if prereleaseIDs.isEmpty || prereleaseIDs.contains(where: { $0.isEmpty }) {
                return nil
            }
            text = String(text[..<dash])
        }

        let core = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count) else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prereleaseIDs)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Semver rule 11.3: a release outranks any pre-release of the same core.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        // Rule 11.4: compare identifiers left to right.
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let aNum = a.allSatisfy(\.isASCIIDigit) ? Int(a) : nil
            let bNum = b.allSatisfy(\.isASCIIDigit) ? Int(b) : nil
            switch (aNum, bNum) {
            case let (x?, y?): return x < y          // numeric vs numeric
            case (.some, .none): return true         // numeric < alphanumeric
            case (.none, .some): return false
            case (.none, .none): return a < b        // ASCII lexical
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
