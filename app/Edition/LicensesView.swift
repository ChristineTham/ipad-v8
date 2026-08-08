import SwiftUI

/// Credits and licensing. Required by docs/licensing.md, not decoration: the
/// 2017 Nokia/Alcatel-Lucent statement is what makes shipping Research Unix
/// possible at all, and it is a covenant not to assert — non-commercial only
/// — rather than a licence. The app is free because of it.
struct LicensesView: View {
    private let statementURL = URL(string: "https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v8/statement_regarding_Unix_3-7-17.pdf")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Research Unix Edition 8") {
                    Text("""
                    Research Unix Editions 8, 9 and 10 are distributable because of \
                    the statement issued by Alcatel-Lucent (now Nokia) on 7 March 2017, \
                    in which the company said it would not assert its copyright rights \
                    over non-commercial copying, distribution or derivative works of \
                    those editions.
                    """)
                    Text("""
                    Two consequences shape this app: it is free, with no advertising and \
                    no in-app purchases, because the statement covers non-commercial use \
                    only; and it is not called "UNIX", because the statement grants no \
                    trademark rights — UNIX is a registered trademark of The Open Group.
                    """)
                    Link("Read the 2017 statement at TUHS", destination: statementURL)
                        .font(.callout)
                }

                section("Preservation") {
                    Text("""
                    The system on the bundled disk survives because of the Unix Heritage \
                    Society and the people who kept the tapes readable — and because Dan \
                    Cross, Norman Wilson and others recovered and published the Edition 8 \
                    tree. The disk image is built by the reproducible procedure published \
                    by Tim Newsham (myv8).
                    """)
                }

                section("Berkeley") {
                    Text("""
                    Edition 8 was built on 4.1c BSD. The BSD-derived code inside it carries \
                    the University of California licence and its attribution requirement.
                    """)
                }

                section("Emulators and components") {
                    component("open-simh", "MIT",
                              "The VAX-11/780 simulator that runs the system.")
                    component("dmd_core", "MIT",
                              "Seth Morabito's DMD 5620 emulator: WE32100 CPU, DUART and framebuffer.")
                    component("DMD 5620 firmware", "GPL (AT&T, 1994)",
                              "The terminal's own ROM, released as source by AT&T.")
                    component("SwiftTerm", "MIT",
                              "Miguel de Icaza's terminal emulator, used for the operator console.")
                }

                section("This app") {
                    Text("""
                    Edition is open source under the MIT licence. It bundles no \
                    documentation scans and no Blit ROMs — neither has a permission \
                    statement covering redistribution.
                    """)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle("Licences")
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.green)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func component(_ name: String, _ licence: String, _ role: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                Text(licence)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
            }
            Text(role).font(.caption)
        }
        .padding(.bottom, 2)
    }
}
