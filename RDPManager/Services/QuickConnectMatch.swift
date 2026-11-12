import Foundation

/// Ranking machines against what has been typed into the quick-connect box.
///
/// Pure arithmetic on strings so it can be tested without a window. The ranking matters more
/// than the matching: with twenty machines, any sensible filter finds the right one, but only
/// a good order puts it first — and first is what Return connects to.
enum QuickConnectMatch {
    /// Lower is better.
    enum Quality: Int, Comparable {
        /// The name begins with what was typed. "sh" for "shop-pc".
        case namePrefix = 0
        /// A later word of the name begins with it. "desk" for "front-desk-pc".
        case wordPrefix = 1
        /// Somewhere in the name.
        case nameContains = 2
        /// In the hostname, group, tags or address instead of the name.
        case elsewhere = 3
        /// The letters appear in order but not together. "spc" for "shop-pc".
        case scattered = 4

        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    struct Result: Equatable {
        var machine: Machine
        var quality: Quality

        static func == (a: Result, b: Result) -> Bool {
            a.machine.id == b.machine.id && a.quality == b.quality
        }
    }

    /// Machines matching `query`, best first. An empty query matches everything, in the
    /// order given, so the box opens showing the list rather than nothing.
    static func rank(_ machines: [Machine], query: String) -> [Result] {
        let needle = query
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else {
            return machines.map { Result(machine: $0, quality: .namePrefix) }
        }

        let scored = machines.compactMap { machine -> Result? in
            quality(of: machine, matching: needle).map { Result(machine: machine, quality: $0) }
        }
        // A stable sort on quality alone, so machines of equal quality keep the order the
        // list is already in — which is the order the user is used to reading.
        return scored.enumerated()
            .sorted { ($0.element.quality, $0.offset) < ($1.element.quality, $1.offset) }
            .map(\.element)
    }

    static func quality(of machine: Machine, matching needle: String) -> Quality? {
        let name = fold(machine.name)
        if name.hasPrefix(needle) { return .namePrefix }

        // Word starts, so "desk" finds "front-desk-pc" without being as good as a prefix.
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return .wordPrefix }

        if name.contains(needle) { return .nameContains }

        let others = [machine.hostname, machine.group, machine.tagsText,
                      machine.lastIP ?? "", machine.notes]
        if others.map(fold).contains(where: { $0.contains(needle) }) { return .elsewhere }

        if isSubsequence(needle, of: name) { return .scattered }
        return nil
    }

    /// Every character of `needle` appears in `haystack`, in order. What makes "spc" find
    /// "shop-pc" without having to type the punctuation.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(haystack)
        for character in needle {
            guard let found = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
