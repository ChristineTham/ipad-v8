# Configuring the machine: from a generic V8 image to a usable ipnx

**Status: plan.** Stage 1 is partly built (`work/fix-identity.exp`,
`work/fix-root-profile.exp`, `work/fix-lostfound.exp`); stages 2 and 3 depend on
work that is not finished yet. Nothing here is claimed as done — see the
checklist at the end and [roadmap.md](roadmap.md).

## The goal

A V8 machine somebody can actually live in, not a demo that boots to `login:`
and impresses for ten minutes. Concretely: it knows its own name, it has an
account that belongs to the person running it, it can see the host's files, and
it is on the network — all without the user typing a single configuration
command.

## Why one script is not enough

`fix-identity.exp` operates on `rp06v8.golden` on the desktop workbench, and
what it writes is baked into the image every copy of the app ships. That is the
right home for anything true of *every* installation. It is the wrong home for
anything true of *this* installation, and the personalisation the goal asks for
is squarely the second kind: the host account's name is not known when the
image is built, and cannot be.

So the work splits in two, and the split is the main design decision here.

**Build time — `work/config.exp`** (the expanded `fix-identity.exp`). Runs once
on the workbench against the golden image. Universal, auditable, and cheap to
re-run when the image is rebuilt. Everything that does not depend on who is
running the app.

**First boot — a provisioner in the app.** Runs once per installation, against
the working disk in Application Support, the first time it boots. The app
already drives V8 over the console channel and knows how to wait for `login:`
and `# ` (`Machine.swift`, `ConsoleLink.swift`); the provisioner is that same
mechanism used deliberately rather than only for boot detection. A marker file
beside `v8.disk` records that it has run, so it never runs twice, and a `Reset
disk` in Settings clears it along with everything else.

There is a tempting third option — put the settings on the `rp1` courier disk
and have `/etc/rc` read them (see [media-exchange.md](media-exchange.md)) — and
it is worth keeping in reserve. It is more machinery than twenty lines of shell
typed once justifies, but it becomes the better answer if first-boot
configuration ever grows past that.

## Stage 1 — identity and an account (no new dependencies)

**`work/config.exp`**, build time. Absorbs today's three fix-*.exp scripts, all
of which are one-shot repairs that should have been one script:

- `/etc/whoami` = `ipnx-v8`. This is the *only* place V8 keeps the system name:
  there is no `hostname(1)`, no `uname(1)`, no `/etc/systemid`, and `/etc/rc`
  never sets one. `login` reads it, which is why it appears above the prompt.
- `/etc/motd` — the licensing position this project runs under, not the 1985
  joke. Verbatim as it stands today.
- `/.profile` — `PATH` including `/usr/games` and `/usr/jerq/bin`, `TERM=dmd`,
  `stty erase ^H kill ^U intr ^C`, and a `fortune`. V8 ships no `/.profile`,
  `/.login` or `/etc/profile` at all, which is why `vi` used to die with `TERM`
  unset. **Erase stays at ^H** — the app maps Delete to 0x08, so ^H is what
  that key sends.
- `lost+found` on `/` and `/usr` via `/etc/mklost+found`, so an autoboot `fsck`
  that has to reconnect an orphan does not abort to single-user.
- `/etc/skel/.profile` — the same shape as root's, minus the root-only bits, so
  a new account gets a working environment.
- The mount points `/n`, `/n/macos`, `/n/home` — empty directories, harmless
  until something mounts on them.

**The account**, first boot, in the app. Named after the host account
(`NSUserName()` on macOS; on iOS there is no such thing, so the app asks once,
defaulting to something neutral). What it does:

- append a `/etc/passwd` line with a real V8 home at `/usr/<user>` and
  `/bin/sh`; V8 has no `adduser`, and `/etc/passwd` is plain text
- `mkdir /usr/<user>`, copy `/etc/skel/.profile` in, `chown`
- no password initially — this is a personal machine emulating a personal
  machine, and a password prompt with no way to recover it is a support burden
  with no security value on a disk the user already owns. Settings can offer to
  set one.

Names need care: V8's login name field is 8 characters and its **filenames are
14 bytes** (this predates 4.2BSD long names), so a host account called
`christie.tham` has to be truncated deterministically, and the app should show
what it chose rather than silently mangling it.

### Why the host share must not be the home directory

The instinct is to point the new account's home at the host's home directory
and be done. It does not survive contact:

- **14-byte filenames.** Anything longer is not representable. A real macOS
  home directory is full of longer names, and the failure is silent truncation
  and collision, not an error.
- **Case.** macOS is case-insensitive by default; V8 is not. `Makefile` and
  `makefile` are one file on one side and two on the other.
- **`login` chdirs to the home directory** and falls back to `/` when it
  cannot. A home directory that only exists when a network mount is up means a
  login before the mount silently lands somewhere else.
- **Dot-files would be shared.** `.profile` written by V8, read by a host shell
  that does not speak its `stty` syntax, is a booby trap in both directions.

So: a real V8 home at `/usr/<user>`, and the host visible *beside* it at
`/n/macos` (the whole share) and `/n/home` (the user's own directory). `/n` is
the name the V8/V10 lineage already uses for attached name spaces, so this is
the house convention rather than an invention.

## Stage 2 — the network up at boot (depends on N3 landing in the image)

N3 proved a V8 kernel with the Interlan NI1010 driver (`il0`) reaching the real
Internet through SIMH's SLiRP NAT — sandbox-safe, so it works on iOS too
([n-track-notes.md](n-track-notes.md)). The shipped image does **not** have that
kernel yet; it still runs the stock one. To make networking a default rather
than an experiment:

- rebuild the golden image around the N3 kernel (this is the gating step, and
  it is also what N0's RP07 migration wants, so the two should happen together)
- `att il0 nat:...` in the app's `boot.conf` **and** `resume.conf`
- `/etc/rc`: bring `il0` up and add the default route. Remember V8 is
  **classful** — the interface's network is `10.0.0.0`, not SLiRP's `10.0.2.0`;
  that one number cost N3 a debugging session
- resolver configuration for `dnsq`, in whatever form V8 expects — to be
  confirmed against the source, not from memory
- Settings: a switch to turn networking off, off by default is wrong here but
  the switch should exist

## Stage 3 — the host's files (depends on N4–N7)

netfs over TCP is the route: its in-kernel client is already `standard` in every
V8 kernel and its mount takes any file descriptor
([networking-plan.md](networking-plan.md)). The remaining work is exactly N4–N7
— derive the wire format, write the host server, write the ~50-line guest
client, then read/write and fold the server into the app.

Once that exists, first boot adds to `/etc/rc`:

- `/n/macos` — a host directory the user picks, sandbox-scoped
- `/n/home` — the user's home directory, same mechanism

Both read-only first. Write access to a real home directory from a 1985 kernel
with 14-byte filenames deserves its own decision, taken once the read path has
been living for a while.

On iOS the same server runs in-process against the app's own documents
directory, which is what makes "Files integration" and "the host share" the
same feature rather than two.

## Checklist

- [ ] Fold `fix-identity.exp`, `fix-root-profile.exp` and `fix-lostfound.exp`
      into `work/config.exp`, idempotent and re-runnable
- [ ] `/etc/skel/.profile` and the `/n`, `/n/macos`, `/n/home` mount points
- [ ] First-boot provisioner in the app: create the account, verify from a
      fresh login, record the marker
- [ ] Name truncation rules, and showing the user what was chosen
- [ ] Rebuild the golden image on the N3 kernel *(blocked on N3 → image)*
- [ ] `att il0 nat:` in both configs; `/etc/rc` brings `il0` up; resolver
- [ ] `/n/macos` and `/n/home` mounted at boot *(blocked on N5–N7)*
- [ ] Settings: host folder picker, networking switch, optional password
