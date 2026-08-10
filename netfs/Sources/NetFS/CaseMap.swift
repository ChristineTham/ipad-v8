import Foundation

/// Presents the repo's case-escaped names to the guest under their true names.
///
/// The V8 tape distinguishes `usr/src/cmd/Mail` from `usr/src/cmd/mail`, and
/// `jerq/src/lib/C` from `jerq/src/lib/c`. macOS is case-insensitive and git
/// cannot check out both spellings either, so the repo stores the loser of each
/// of the 17 colliding paths percent-escaped -- `Mail` as `%4Dail`.
///
/// V8's filesystem has no such problem, so the guest should simply see the true
/// names, and the translation belongs here rather than in a copy step on the
/// other side of the wire. Serving the tree directly is the whole point: the
/// source stays on the share and only build products land on disk.
///
/// It is also not optional. A `struct direct` name field is 14 bytes, and
/// `%43%49%52%43%4C%45` -- the escaped spelling of `CIRCLE` -- is 18. The
/// escaped names physically cannot be represented in a V8 directory entry;
/// only the true ones fit.
struct CaseMap {
    /// keyed by the on-disk (stored) parent directory
    private var toTrue: [String: [String: String]] = [:]
    private var toStored: [String: [String: String]] = [:]

    var isEmpty: Bool { toTrue.isEmpty }
    var count: Int { toTrue.values.reduce(0) { $0 + $1.count } }

    /// Loads `<root>/CASEMAP`, whose lines are (true parent, stored, true).
    ///
    /// The parent recorded there is a *true* path, but lookups arrive with the
    /// *stored* path the filesystem actually has, so each parent is translated
    /// through the mappings already built. That ordering is why CASEMAP is
    /// written parents-first: once `%4Dail` is known as `Mail`, nothing spelled
    /// the old way resolves any more.
    init(root: String) {
        let path = (root as NSString).appendingPathComponent("CASEMAP")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        var prefixes: [(stored: String, real: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            let trueParent = String(f[0]), stored = String(f[1]), real = String(f[2])

            var storedParent = trueParent
            for p in prefixes where storedParent == p.real || storedParent.hasPrefix(p.real + "/") {
                storedParent = p.stored + storedParent.dropFirst(p.real.count)
            }
            let abs = storedParent == "." ? root
                : (root as NSString).appendingPathComponent(storedParent)

            toTrue[abs, default: [:]][stored] = real
            toStored[abs, default: [:]][real] = stored
            prefixes.append((storedParent + "/" + stored, trueParent + "/" + real))
        }
    }

    /// Listing: what the guest should see for a name that is on disk.
    func shown(parent: String, onDisk name: String) -> String {
        toTrue[parent]?[name] ?? name
    }

    /// Lookup: what is on disk for a name the guest asked for.
    func onDisk(parent: String, shown name: String) -> String {
        toStored[parent]?[name] ?? name
    }
}
