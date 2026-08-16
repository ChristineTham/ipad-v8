/**
 * Build a site-absolute URL that respects Astro's configured `base`.
 *
 * The site is a project page served from a sub-path
 * (https://christham.net/ipnx/), so every internal link and asset must be
 * prefixed with the base — a bare "/privacy" would resolve against the domain
 * root, which is a different site entirely. Deriving the prefix from
 * `import.meta.env.BASE_URL` rather than hard-coding "/ipnx/" means renaming
 * the repo again, or moving to a domain root with `base: '/'`, needs only an
 * astro.config change.
 *
 *   href('/')            → '/ipnx/'
 *   href('/privacy')     → '/ipnx/privacy'
 *   href('assets/x.png') → '/ipnx/assets/x.png'
 */
export function href(path = '/'): string {
  const base = import.meta.env.BASE_URL; // '/ipnx/' (Astro guarantees a trailing slash)
  const clean = path.replace(/^\/+/, '');
  return base.endsWith('/') ? base + clean : `${base}/${clean}`;
}
