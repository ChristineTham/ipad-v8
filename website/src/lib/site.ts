/**
 * Site-wide facts. Kept in one place so a release only touches this file —
 * the version, download link and checksum appear on several pages.
 */

export const APP = {
  name: 'ipnx',
  /** What the machine calls itself. Generated from v8/RELEASE in the repo. */
  system: 'ipnx Edition 8 Release 1.0',
  tagline: 'Bell Labs Research Unix, booted and carried forward.',
  version: '1.0',
  minOS: 'macOS 26 or later',
  /** Apple silicon only: the VAX and WE32100 cores are built arm64. */
  architectures: 'Apple silicon',
} as const;

/**
 * WHO PUBLISHES THIS, and why the two names differ.
 *
 * The project is a personal, non-commercial one and is published from a
 * personal account — deliberately, because Research Unix Editions 8–10 are
 * distributable only under Nokia/Alcatel-Lucent's 2017 statement, which
 * reaches NON-COMMERCIAL use. Publishing under a company's name would sit
 * badly against that, whatever the intent.
 *
 * The code signature is a separate question and names a company, because a
 * Developer ID certificate has to belong to an enrolled team and this one
 * does. It is stated plainly on the download page rather than hidden: someone
 * verifying the signature will see the name, and finding an unexplained
 * company there is worse than reading why it is there.
 */
export const AUTHOR = {
  name: 'Christine Tham',
  site: 'https://christham.net',
  email: 'chris.tham@hellotham.com',
} as const;

export const SIGNER = {
  /** Exactly as `codesign -dv` prints it. */
  authority: 'Developer ID Application: Hello Tham Pty. Ltd. (RPL5R637DS)',
  name: 'Hello Tham Pty. Ltd.',
  teamID: 'RPL5R637DS',
} as const;

export const REPO = 'https://github.com/ChristineTham/ipnx';

export const DOWNLOAD = {
  /** Release assets live on GitHub Releases — a binary does not belong in the
   *  site repo, where it would bloat every clone forever. */
  url: `${REPO}/releases/latest/download/ipnx.dmg`,
  releasesPage: `${REPO}/releases/latest`,
  fileName: 'ipnx.dmg',
  /** Filled by tools/release-mac.sh from the artefact it actually produced.
   *  Empty means "not built yet" and the download page omits the block rather
   *  than printing a number nobody can check. */
  size: '21.1 MB',
  sha256: 'd93a1c756a6610da607dc58998c8cb58c7294038affb32b03f0c2c8ad37c4a25',
} as const;

/** Primary nav. Secondary/legal links live in the footer. */
export const NAV = [
  { label: 'The machine', href: '/machine' },
  { label: 'Screenshots', href: '/screenshots' },
  { label: 'Manual', href: '/manual' },
  { label: 'Download', href: '/download' },
  { label: 'Support', href: '/support' },
] as const;

/** Manual sections — drives the manual index, the sidebar, and prev/next. */
export const MANUAL = [
  {
    slug: 'getting-started',
    title: 'Getting started',
    blurb: 'First launch, the account it makes for you, and how to log in.',
  },
  {
    slug: 'terminals',
    title: 'The terminals',
    blurb: 'The console, tty01–tty07, and why there are windows rather than tabs.',
  },
  {
    slug: 'the-5620',
    title: 'The DMD 5620',
    blurb: 'The bitmapped terminal, its two screen sizes, and the phosphor.',
  },
  {
    slug: 'mux-and-layers',
    title: 'mux and layers',
    blurb: 'Downloading the window system, sweeping a layer, and running jim.',
  },
  {
    slug: 'sharing-files',
    title: 'Sharing files with your Mac',
    blurb: '/n/macos and /n/home over Weinberger’s network file system.',
  },
  {
    slug: 'networking',
    title: 'Networking',
    blurb: 'The Interlan card, TCP/IP, name resolution, and reaching the Internet.',
  },
  {
    slug: 'settings',
    title: 'Settings',
    blurb: 'Screen, phosphor, scaling, terminal speed, snapshots and the disk.',
  },
  {
    slug: 'troubleshooting',
    title: 'Troubleshooting',
    blurb: 'When the machine will not stop, and what a clean halt is for.',
  },
] as const;
