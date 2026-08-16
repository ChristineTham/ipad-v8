// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

/** Sub-path this project page is served from. Single source of truth for the
 *  `base`; keep it equal to the GitHub repo name, since that is what decides
 *  the URL. The repo was renamed ipad-v8 → ipnx on 2026-08-16 and this moved
 *  with it. */
const BASE = '/ipnx';

// https://astro.build/config
export default defineConfig({
  // Public URL: https://christham.net/ipnx/
  //
  // `site` is the CUSTOM domain, not christinetham.github.io. The apex domain
  // is the CNAME of the *user-site* repo (ChristineTham/christinetham.github.io
  // → christham.net), and GitHub serves project pages of the same account
  // underneath it — so github.io URLs 301 here. Pointing `site` at github.io
  // would emit canonical/og:url/og:image on the redirecting domain, which is
  // wrong for SEO and for link unfurls. This repo needs no CNAME of its own;
  // it inherits the domain.
  //
  // `site` + `base` make canonical URLs and asset paths resolve under the
  // sub-path. Never hard-code "/ipnx/" in a template — use the `href()` helper
  // in src/lib/paths.ts, which is built from `import.meta.env.BASE_URL`, so the
  // site survives another rename.
  site: 'https://christham.net',
  base: BASE,

  // Emit dist/privacy.html rather than dist/privacy/index.html.
  //
  // THIS IS AN APP STORE REQUIREMENT IN DISGUISE. App Store Connect's Privacy
  // Policy URL and Support URL fields are registered once and quoted in the
  // wild afterwards, and people write them either way. GitHub Pages resolves
  // `<path>.html` BEFORE `<path>/index.html`, so with 'file' format a single
  // artefact answers both forms:
  //     /ipnx/privacy       → privacy.html ✓
  //     /ipnx/privacy.html  → privacy.html ✓
  //
  // Redirects are a trap here. Astro's `redirects` honours this same format
  // setting, so with the default 'directory' a key of '/privacy.html' emits a
  // privacy.html/ *directory* — it serves /privacy.html/ and 404s
  // /privacy.html. Hand-written redirect files in public/ are worse: a
  // public/privacy.html SHADOWS the real /privacy route by the resolution
  // order above, producing a redirect loop.
  build: { format: 'file' },

  vite: {
    plugins: [tailwindcss()],
  },
});
