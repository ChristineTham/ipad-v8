import Foundation

/// Which machine this is — everything that differs between the Eighth Edition
/// and the Tenth, as data rather than as strings scattered through `Machine`.
///
/// WHY THIS EXISTS. `Machine` had `v8` written into it in eight places: the
/// Application Support subdirectory, the working disk's name, the pending
/// disk's, the bundled `.disk` and `.disk.id` resources, the boot ROM, and the
/// two SIMH configs. Adding the Tenth Edition beside it meant finding all of
/// them first, which is archaeology rather than engineering — and the project's
/// own experience is that a list of the same thing written twice disagrees
/// silently. Now there is one list.
///
/// **V10 IS A DIFFERENT MACHINE, NOT A DIFFERENT FILENAME.** It boots off an
/// **RA81 on `rq0`** through an MSCP/UDA50A, where V8 uses an **RP07 on `rp0`**
/// on the Massbus; and it is started by **`run FA02`** — the entry point of the
/// tape's own boot ROM, which loads `/unix` itself — where V8 is started by
/// `load -o bootV8 0` and `run 2`. Every value in `v10` below is copied from
/// the boot sequence `tools/v10drive.exp` has actually booted, not inferred.
struct MachineSpec: Identifiable, Hashable {

    /// Also the Application Support subdirectory: `ipnx/<id>`.
    let id: String

    /// What the user is shown.
    let name: String

    /// The working disk's filename, inside the support directory and inside
    /// the bundle. `v8.disk` is both the bundled resource and the working
    /// copy's name, and the identity stamp is this plus `.id`.
    let diskFile: String

    /// The boot ROM embedded beside the disk, if the machine needs one loaded.
    let bootFile: String

    /// `set cpu …` — one line for V8 (its idle pattern) and one for V10 (its
    /// memory size).
    let cpu: [String]

    /// `set cpu …` on the RESUME path, which is not the same list.
    ///
    /// V8 must re-issue its idle pattern, because `UNIT_IDLE` survives a
    /// save/restore (it is not in `UNIT_RFLAGS`) while `cpu_idle_mask` does
    /// NOT — so a restored machine idles only if told to again. V10 must NOT
    /// re-issue `set cpu 8m`: sizing memory after `restore` would write over
    /// the state that was just restored. Different lists, and conflating them
    /// would be a bug that only shows up on the second launch.
    let resumeCpu: [String]

    /// Device lines that must come BEFORE the shared `set dz lines=8`.
    ///
    /// V10's proven boot sequence enables the DZ before configuring it, and the
    /// order is not cosmetic: setting the line count on a disabled device is not
    /// something to rely on. V8 has always come up without this, so its list is
    /// empty rather than newly populated — a refactor that changes what the
    /// working machine emits is not a refactor.
    let preDevices: [String]

    /// Attaching the system disk. Two lines on both machines, but different
    /// controllers.
    let disk: [String]

    /// Devices this machine wants and the other does not.
    let extraDevices: [String]

    /// Getting the CPU running, after the disk is attached and the console is
    /// configured. The last line is always the one that starts it.
    let boot: [String]

    /// What the kernel prints once it is spinning and the disk is safe.
    ///
    /// V8's `boot()` calls `update()`, prints `syncing disks... done` and then
    /// `halting (in tight loop)` before spinning at IPL 31 — so the word
    /// "halting" means the I/O has drained, which a timer never would. V10's
    /// `boot()` is two lines (`lsys/md/machdep.c`): `if (howto&RB_HALT)
    /// death();`, and `death()` prints **`death`**. Nothing else.
    ///
    /// GETTING THIS WRONG COSTS /usr, and it did. Waiting for "halting" on V10
    /// simply times out, so the provisioning restart relaunched over a guest
    /// that had never confirmed anything — and because V10 neither syncs nor
    /// unmounts on halt, `/usr` kept `s_valid = 0`. The next boot then answered
    ///
    ///     mount /dev/ra0c on /usr type 0: In use
    ///
    /// and carried on into multi-user with root's empty `/usr` showing through:
    /// `fs.c:107` refuses a bitmapped filesystem whose `s_valid` is clear, and
    /// only `fsoff` — a real unmount — sets it back.
    let haltMarker: String

    /// The operator's shutdown, in order.
    ///
    /// V10 needs `umount -a` and V8 does not, and the difference is not style.
    /// V8's `boot()` flushes for you; V10's does nothing at all, so the
    /// userland `sync` is the whole flush — and neither kernel unmounts, but
    /// only V10 then refuses to remount (V8's autoboot `fsck` self-heals).
    /// `umount -a` walks mtab backwards, so nothing has to be named.
    let shutdown: [String]

    /// THE EIGHTH EDITION, exactly as the app has always booted it.
    static let v8 = MachineSpec(
        id: "v8",
        name: "Eighth Edition",
        diskFile: "v8.disk",
        bootFile: "bootV8",
        // 4.1BSD's idle loop, which V8's kernel matches unchanged because it is
        // 4.1BSD-derived. Measured at the login prompt: ~97% of a core before,
        // ~2.7% after (with the three UNIT_IDLE flags libsimh patches in).
        cpu: ["set cpu idle=4.1BSD"],
        resumeCpu: ["set cpu idle=4.1BSD"],
        preDevices: [],
        disk: ["set rp0 rp07", "at rp0 v8.disk"],
        // The TE16 is configured but never attached: V8's `ht' driver panics
        // the kernel on a 16-bit Massbus register read, which is why the tape
        // route is dead and media goes through `rp1' as a raw courier.
        extraDevices: ["set tu0 te16"],
        boot: ["load -o bootV8 0", "run 2"],
        haltMarker: "halting",
        // Unchanged from what the app has always sent.  V8's boot() flushes and
        // waits for the I/O itself, and its autoboot fsck repairs an unclean
        // stop, so there is nothing to add here.
        shutdown: ["cd /; sync; sync", "/etc/halt"]
    )

    /// THE TENTH EDITION. Every line is from the sequence
    /// `tools/v10drive.exp`'s `v10_boot` has booted on the 780 since K9 —
    /// including under `libsimh`'s own `vax780cli`, which is the static library
    /// both app targets link, so this is the code that ships rather than a
    /// desktop build.
    ///
    /// NOT WIRED INTO THE UI YET. It is here so that the machine-dependent
    /// values live in one reviewable place; carrying a second machine also
    /// needs a second `Machine`, its own windows and its own shares, which is
    /// its own phase.
    static let v10 = MachineSpec(
        id: "v10",
        name: "Tenth Edition",
        diskFile: "v10.disk",
        // `lsys/boot/star/uda' — the tape's own UDA50A boot ROM, loaded at
        // FA00 and entered at FA02. It reads /unix off the disk itself, which
        // is why V10 needs no equivalent of bootV8's second-stage loader.
        bootFile: "uda",
        // `idle=4.1BSD' WORKS ON V10, MEASURED: 99.8% of a core down to 1.7%
        // (tools/v10-idle.sh, an A/B on the same disk with one variable). That
        // is better than V8's 2.7%, and the guest's clock still reads correctly
        // afterwards — an idle that slept through timer interrupts would be
        // worse than none.
        //
        // It works because V10's kernel carries the SAME idle loop. SIMH's
        // 4.1BSD-family detection (`VAX_IDLE_ULT1X', vax_cpu.c:2579) fires on an
        // FFS that finds no set bits, at IPL 0, in system space, below virtual
        // 0x3000. `lsys/ml/swtch.s' has the identical four instructions V8's
        // `locore.s' does — byte-for-byte identical source — and the built
        // kernel puts `sw1' at 0x80001136, i.e. low 0x1136, inside that window.
        // All five conditions hold, and the machine agrees.
        //
        // `set cpu 8m' is the memory size every V10 harness uses.
        cpu: ["set cpu 8m", "set cpu idle=4.1BSD"],
        // The idle pattern must be re-issued after `restore' -- `cpu_idle_mask'
        // is not saved -- and the MEMORY SIZE must not be, because sizing memory
        // after a restore writes over what was just restored. This is the whole
        // reason the two lists are separate.
        resumeCpu: ["set cpu idle=4.1BSD"],
        preDevices: ["set dz enable"],
        disk: ["set rq0 ra81", "attach rq0 v10.disk"],
        extraDevices: [],
        // The registers are deposited because the ROM expects them: sp at 200
        // and r1/r3/r5 cleared, exactly as v10_boot does before `run FA02'.
        boot: ["load -o uda FA00",
               "dep sp 200", "dep r1 0", "dep r3 0", "dep r5 0",
               "run FA02"],
        haltMarker: "death",
        // `umount -a' is the load-bearing line: without it /usr keeps
        // s_valid = 0 and the next boot cannot mount it.  Two syncs around a
        // sleep because V10's sync(2) sets B_ASYNC and returns before the disk
        // has the block (lsys/io/bio.c:692), so the flush needs time it does not
        // wait for -- which is exactly what tools/v10drive.exp's v10_halt does.
        shutdown: ["cd /; sync", "/etc/umount -a", "sync", "/etc/halt"]
    )

    static let all: [MachineSpec] = [.v8, .v10]

    /// The UserDefaults key. Read directly rather than through `Settings`,
    /// because `Machine` is constructed in `IpnxApp.init` and needs its spec
    /// before any ObservableObject exists.
    static let defaultsKey = "machine.edition"

    /// Whether this machine's media is actually in the bundle.
    ///
    /// The embed phase WARNS and carries on when `work/` has no image, so a
    /// build without V10 media is a normal build — and offering an edition the
    /// bundle cannot provision would turn a missing file into a launch that
    /// throws `mediaMissing` with nothing to say why.
    var isAvailable: Bool {
        Bundle.main.url(forResource: diskFile, withExtension: nil) != nil
            && Bundle.main.url(forResource: bootFile, withExtension: nil) != nil
    }

    /// Only the editions this build can actually boot.
    static var available: [MachineSpec] { all.filter(\.isAvailable) }

    /// Which machine to bring up, and it FALLS BACK rather than failing.
    ///
    /// A stored preference can outlive the media it names: the user selects the
    /// Tenth Edition, the next build is made on a checkout without
    /// `work/v10gold/`, and the bundle no longer carries `v10.disk`. Booting
    /// what is there beats refusing to boot at all, and V8 is always present in
    /// a real build.
    static var current: MachineSpec {
        let want = UserDefaults.standard.string(forKey: defaultsKey) ?? v8.id
        if let m = all.first(where: { $0.id == want }), m.isAvailable { return m }
        return v8
    }
}
