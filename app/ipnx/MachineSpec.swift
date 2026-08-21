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
        boot: ["load -o bootV8 0", "run 2"]
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
        // NO `set cpu idle' HERE, AND THAT IS A KNOWN GAP RATHER THAN AN
        // OMISSION. V8's `idle=4.1BSD' matches its kernel because that kernel
        // is 4.1BSD-derived; V10's is not, and no V10 harness has ever set an
        // idle pattern — measured 43:20 of CPU in 44:24 elapsed, i.e. a core
        // burned throughout. Harmless on a desktop and not harmless on an iPad
        // battery, so finding V10's idle loop is work this machine needs before
        // it ships. `set cpu 8m' is the memory size the harnesses use.
        cpu: ["set cpu 8m"],
        // Deliberately empty: see resumeCpu. And when V10's idle loop is found,
        // it belongs in BOTH lists, for the reason V8's is in both.
        resumeCpu: [],
        preDevices: ["set dz enable"],
        disk: ["set rq0 ra81", "attach rq0 v10.disk"],
        extraDevices: [],
        // The registers are deposited because the ROM expects them: sp at 200
        // and r1/r3/r5 cleared, exactly as v10_boot does before `run FA02'.
        boot: ["load -o uda FA00",
               "dep sp 200", "dep r1 0", "dep r3 0", "dep r5 0",
               "run FA02"]
    )

    static let all: [MachineSpec] = [.v8, .v10]
}
