# The website, and shipping a Mac release

*How `website/` is built and published, and how `tools/release-mac.sh` produces
a notarised download. Both are one command; this file is the reasoning, and the
traps that are invisible until they bite someone else's Mac.*

## The site

`website/` is an Astro 7 + Tailwind v4 project, published to
**<https://christham.net/ipnx/>** by `.github/workflows/deploy-website.yml` on
every push that touches it.

### Why the URL looks like that

It is a **project page** served under the account's user-site custom domain.
`ChristineTham/christinetham.github.io` has the CNAME `christham.net`, and
GitHub serves project pages of the same account underneath it — so
`christinetham.github.io/ipnx/` **301s** to `christham.net/ipnx/`. That is why
`astro.config.mjs` sets `site: 'https://christham.net'` rather than the
github.io host: canonical, `og:url` and `og:image` must not name a redirecting
domain. This repo needs no `CNAME` file of its own; it inherits the domain.

`base` is `/ipnx` and must equal the repo name, because that is what decides
the path. It moved once already, when the repo was renamed from `ipad-v8`.

### `build.format: 'file'` is an App Store requirement in disguise

It emits `dist/privacy.html` rather than `dist/privacy/index.html`. GitHub
Pages resolves `<path>.html` **before** `<path>/index.html`, so one artefact
answers both forms:

	/ipnx/privacy       -> privacy.html
	/ipnx/privacy.html  -> privacy.html

This matters because App Store Connect's **Privacy Policy URL** and **Support
URL** are registered once and then quoted in the wild, and people write them
either way. Both are asserted live after every deploy:

```bash
for u in privacy privacy.html support support.html; do
  curl -s -o /dev/null -w "%{http_code} $u\n" -L "https://christham.net/ipnx/$u"
done
```

Redirects are a trap here rather than a fix. Astro's `redirects` honours the
same `format` setting, so a key of `/privacy.html` under the default
`'directory'` emits a `privacy.html/` **directory** — serving `/privacy.html/`
and 404ing `/privacy.html`. A hand-written `public/privacy.html` is worse: it
*shadows* the real route by the resolution order above, producing a loop.

### Never hard-code the base

Every internal link and asset goes through `href()` in `src/lib/paths.ts`,
which is built from `import.meta.env.BASE_URL`. A bare `/privacy` resolves
against the domain root, which is a different site entirely.

### The design, and why it is not the app icon

The icon is a stylised New Hampshire licence plate — the app's joke. The site
is a **Bell Labs technical report**: paper and ink, serif prose in the troff
manner, hairline rules, Bell blue as the single accent, monospace whenever the
machine speaks. Light is the primary appearance, which is the opposite of the
usual product site and is the point: a typeset page is what is being evoked.
Dark is a genuine second appearance — a phosphor terminal, the project's other
half — not a tinted inversion.

Colour lives only in `src/styles/global.css`, as semantic tokens resolved with
`light-dark()`. Two rules that are easy to get wrong:

- `light-dark()` takes **colours, not values**. Wrapping a whole gradient in it
  makes the declaration invalid, which silently renders gradient-filled text
  transparent. Put it on each stop.
- A `@theme` block is the fallback for a browser without `light-dark()`, so the
  values there should be the appearance you would rather a stranger saw.

### Quoting the machine

`<Crt text={...} />` renders a transcript as **selectable text**, never a
picture of one — the subject is a machine that prints things, and an image of
output cannot be copied, searched, or read aloud.

**The transcript is a prop, not a slot,** and that is load-bearing: Astro
compiles element children as JSX children and normalises the whitespace between
them, so a multi-line block passed as a slot arrives as **one line** inside a
`<pre>`. A single JavaScript string has no such problem.

The same class of bug bit the Open Graph card (`scripts/make-og.mjs`): SVG
collapses whitespace runs like HTML, so `$ ipnxfetch` rendered as `$ipnxfetch`
and the column alignment vanished. `xml:space="preserve"` fixes it.

## The Mac release

```bash
tools/release-mac.sh              # archive → notarise → dmg → notarise → verify
tools/release-mac.sh --skip-notarise   # local smoke test
```

It produces `build/release/ipnx.dmg`, **stapled**, so it opens on a Mac that
has never heard of it and has no network to ask Apple with. Then:

```bash
gh release create v1.0 build/release/ipnx.dmg --title "ipnx Edition 8 Release 1.0" --notes-file notes.md
```

### Both layers get notarised

The `.dmg` is what gets downloaded, so it is what has to carry the ticket. A
stapled app inside an unstapled image still makes the first launch phone home,
which is exactly what stapling exists to avoid. So: notarise and staple the
app, build the image, sign it, notarise and staple **that**.

### Two bugs the script now protects against, both found by running it

- **`codesign -dv … | grep -q` fails under `pipefail`.** `grep -q` exits on the
  first match, `codesign` takes SIGPIPE, and the pipeline reports failure — so
  the check fails precisely when it should pass. It printed *"hardened runtime
  is NOT enabled"* directly beneath a line reading `flags=0x10000(runtime)`.
  Capture once into a variable, then test the copy.
- **`notarytool submit --wait` exits 0 for a REJECTED submission.** The verdict
  is in the output, not the status. The `notarise()` helper insists on
  `status: Accepted` and prints the `notarytool log` command if not.

### What must be true before it will run

`tools/app-check.sh --full` is a precondition, so a release cannot ship a disk
that is not the committed golden. Signing settings live in the project and are
not the script's business: hardened runtime on, `--timestamp`, manual signing
with `Developer ID Application`, team `RPL5R637DS`, `arm64`.

### The signature names a company; the project does not

A Developer ID certificate must belong to an enrolled team, and the one
available is Hello Tham Pty. Ltd. The project is personal and non-commercial,
which is what the 2017 covenant permits. This is **stated on the download
page** rather than left for someone to discover in `codesign -dv`, because an
unexplained company in a signature looks worse than an explained one.

## Numbers are written, not typed

`release-mac.sh` writes the artefact's size and sha256 into
`website/src/lib/site.ts`. The download page omits the checksum block entirely
when it is empty — a placeholder hash invites a check that cannot pass and
teaches people to ignore the result.

## Screenshots

`tools/shot-windows.swift` lists an application's windows with their
CoreGraphics ids, because `screencapture -l` wants one and nothing in the shell
hands you one (`osascript` sees accessibility elements, a different namespace;
`screencapture -w` is interactive). Capturing by window id rather than screen
rectangle is what keeps the shot clean.

Two things learned taking the first set:

- A first-boot machine has the **provisioning transcript** in `tty01`'s
  scrollback — root creating the account. It is not something to photograph.
  Open a fresh terminal, or use one that has scrolled.
- `mux` with a layer swept open needs a mouse in a human hand. The screenshots
  page says so rather than showing something else.
