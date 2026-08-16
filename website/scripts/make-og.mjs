/**
 * Generate public/assets/og.png — the card social platforms show when someone
 * links the site.
 *
 *     node scripts/make-og.mjs
 *
 * Composed here rather than exported from a design tool for two reasons: it
 * has to stay in step with the release string, and it must live in `public/`
 * with a STABLE filename. An image processed by astro:assets gets a
 * content-hashed name that changes whenever it is re-exported, and social
 * crawlers cache by URL — so a redesign would silently keep serving the old
 * card, or none.
 *
 * 1200×630 is the size every platform crops from.
 */
import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';

const RELEASE = 'ipnx Edition 8 Release 1.0';

/** Palette, kept in step with src/styles/global.css (paper appearance). */
const PAPER = '#fbf9f4';
const INK = '#15130f';
const MUTED = '#6b665c';
const RULE = '#ddd6c7';
const CRT_BG = '#08100c';
const PHOSPHOR = '#7fe3ac';

/** XML-escape anything interpolated into the SVG. */
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);

const serif = 'Iowan Old Style, Palatino, Georgia, Times New Roman, serif';
const mono = 'SF Mono, Menlo, Consolas, monospace';

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="${PAPER}"/>

  <!-- running head, as on the site -->
  <text x="72" y="72" font-family="${mono}" font-size="18" letter-spacing="2.4" fill="${MUTED}">
    COMPUTING SCIENCE
  </text>
  <text x="1128" y="72" text-anchor="end" font-family="${mono}" font-size="18" letter-spacing="2.4" fill="${MUTED}">
    RESTORED 2026
  </text>
  <line x1="72" y1="96" x2="1128" y2="96" stroke="${RULE}" stroke-width="2"/>
  <line x1="72" y1="102" x2="1128" y2="102" stroke="${INK}" stroke-width="4"/>

  <!-- title -->
  <text x="72" y="216" font-family="${serif}" font-size="88" font-weight="700" fill="${INK}">ipnx</text>
  <text x="72" y="300" font-family="${serif}" font-size="46" fill="${INK}">Bell Labs Research Unix,</text>
  <text x="72" y="356" font-family="${serif}" font-size="46" fill="${INK}">booted and carried forward.</text>

  <text x="72" y="418" font-family="${serif}" font-size="26" fill="${MUTED}">
    Eighth Edition on an emulated VAX-11/780, shown through a DMD 5620.
  </text>

  <!-- a terminal, because that is what this is -->
  <!-- xml:space="preserve" is load-bearing: SVG collapses runs of whitespace
       like HTML does, so without it "$ ipnxfetch" renders as "$ipnxfetch" and
       the column alignment below silently disappears. -->
  <rect x="72" y="452" width="1056" height="112" rx="3" fill="${CRT_BG}"/>
  <text x="96" y="492" xml:space="preserve" font-family="${mono}" font-size="20" fill="${PHOSPHOR}"><tspan opacity="0.55">$ </tspan>ipnxfetch</text>
  <text x="96" y="524" xml:space="preserve" font-family="${mono}" font-size="20" fill="${PHOSPHOR}">OS:   ${esc(RELEASE)}</text>
  <text x="96" y="550" xml:space="preserve" font-family="${mono}" font-size="20" fill="${PHOSPHOR}">CPU:  VAX-11/780 @ 5 MHz (emulated)</text>

  <text x="1128" y="600" text-anchor="end" font-family="${mono}" font-size="17" letter-spacing="1.6" fill="${MUTED}">
    CHRISTHAM.NET/IPNX
  </text>
</svg>`;

await mkdir(new URL('../public/assets/', import.meta.url), { recursive: true });
const out = new URL('../public/assets/og.png', import.meta.url);
await sharp(Buffer.from(svg)).png().toFile(out.pathname);

const meta = await sharp(out.pathname).metadata();
console.log(`og.png  ${meta.width}×${meta.height}`);
