# CLAUDE.md — Maxi 80 promo website

Single-page **French** marketing site for the **Maxi 80 app** (not the radio station itself — the
station lives at [maxi80.com](https://maxi80.com), which the footer links to). Plain, dependency-free
**HTML + CSS + JS**. No build step, no framework, no bundler — open `index.html` directly or serve the
folder statically.

```
website/
├── index.html    markup, all copy (French only)
├── styles.css    the whole design system (design tokens live in :root)
├── script.js     sticky-nav border, scroll-reveal, hero phone crossfade
├── CLAUDE.md     this file
└── assets/       logo, app icon, and the fr-FR screenshots (see "Assets" below)
```

## How to work on this

- **Copy is French, always.** Every user-facing string is French, in the app's playful voice
  (`Épaulettes et gros tubes`, `Montez le son`). Match that register. The source of truth for product
  copy is the fastlane metadata — `Darwin/fastlane/metadata/fr-FR/` and
  `Android/fastlane/metadata/android/fr-FR/`. Reuse their wording; don't invent new claims.
- **Preview it.** No headless browser is installed globally, but a Puppeteer-cached Chrome is at
  `~/.cache/puppeteer/chrome/mac_arm-*/`. To screenshot: import `puppeteer-core` by **absolute path**
  from `~/.npm/_npx/<hash>/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js` (ESM
  ignores `NODE_PATH`). **Gotcha:** `fullPage` screenshots leave mid-page sections black because the
  scroll-reveal `IntersectionObserver` never fires without a real viewport scroll — either scroll the
  page programmatically before capturing, or capture per-section with `el.scrollIntoView()`.
- **Keep the quality floor:** responsive to mobile, visible focus rings (`:focus-visible`), and
  everything animated must be gated behind `@media (prefers-reduced-motion: reduce)`.

## Design system (don't drift from this)

- **Concept:** dark near-black canvas (chosen so the dark-background neon logo drops in cleanly),
  warm amber/gold + orange accents pulled straight from the app UI.
- **Signature element:** the animated **neon graphic-EQ** (`.eq`) — the one place the logo's full
  rainbow spectrum is spent. It appears in the hero and as a tall vertical variant (`.eq--tall`) in the
  car/"Route" section. **Keep the rest of the page disciplined** — black / white / amber only.
  If you add a section, do NOT sprinkle rainbow around; the EQ is the memorable thing.
- **Palette + type are tokens in `:root`** (`--ink`, `--amber`, `--n1..--n6` neon ramp;
  fonts: Unbounded display / Manrope body / Space Mono labels). Change colors there, not inline.
- **Eyebrows are numbered** (`01 — PARTOUT` …) because the page is a real sequence. If you reorder
  sections, renumber them.

## Sections (top → bottom)

nav → hero → `#ecrans` (platform grid) → `#coverflow` (history) → `#pochettes` (HD covers) →
`#salon` (Apple TV + Android TV) → `#route` (CarPlay/Android Auto) → extras grid → `#telecharger`
(CTA) → footer.

## Platforms & store links (kept in sync in TWO places: hero + CTA)

- Supported: **iPhone, iPad, Mac, Android, CarPlay, Android Auto, Apple TV, Android TV.**
- App Store (universal — covers iPhone/iPad/**Mac**, so no separate Mac link needed):
  `https://apps.apple.com/be/app/maxi80/id335551519`
- Google Play: `https://play.google.com/store/apps/details?id=com.stormacq.android.maxi80`
- If a link changes, update **both** the hero `.store-row` and the CTA `.store-row--center`.

## Interactive bits (`script.js`)

- **Hero phone crossfade:** `.phone__shot` images cycle iOS ⇄ Android every 3.5 s (0.8 s dissolve),
  with a `.phone__badge` pill showing the current platform. It pauses on tab-hide and is disabled
  under reduced-motion (falls back to the static iOS shot). To add a third shot, just add another
  `<img class="phone__shot" data-platform="…">`; the cycler is length-agnostic.
- **Scroll reveal:** elements get `.reveal` → `.is-in` via `IntersectionObserver`. Reduced-motion and
  no-IO browsers get everything shown immediately.

## Assets

Copied from the repo's fastlane dirs + the old iOS graphics repo
(`/Users/sst/code/maxi80/maxi-80-ios-swift/graphics`). Screenshots are the **fr-FR** set only.
If screenshots are regenerated, re-copy the fr-FR versions into `assets/` (filenames:
`shot-now-playing.png` iOS, `shot-android-phone.png` Android, `shot-history.png`, `shot-coverflow.png`,
`tv-apple.png`, `tv-android.png`, `logo-neon.png`, `app-icon.png`).

## Deploy & custom domain (READ before touching CNAME)

Deployed via `.github/workflows/pages.yml` (push to `main` touching `website/**`) to
**`https://maxi80-com.github.io/maxi80-app/`**. The intended custom domain is
**`app.maxi80.com`**, but its **DNS is not set up yet** (`nslookup app.maxi80.com` → `NXDOMAIN`;
same blocker tracked in `docs/publish.md §2`).

- **There is deliberately NO `CNAME` file** right now. A `CNAME` makes GitHub Pages 301-redirect
  the whole site to that domain whether or not it resolves — with DNS dead, those redirects
  dead-end and images render as broken placeholders (the redirect propagates unevenly across CDN
  edges, so it looks like "only some images break"). This already bit the `#salon` TV shots once.
- **When `app.maxi80.com` DNS is live** (and the Pages custom domain is added + verified in the repo
  settings): re-add `website/CNAME` containing the single line `app.maxi80.com`. Only then.
- Until then the site is reachable at the `github.io` URL above; nothing else needs changing.

## Known TODO / loose ends

- Fastlane `marketing_url` / `support_url` / `privacy_url` (all locales) are still `REPLACE-ME-*`.
  If this site becomes the marketing URL, point them here and add a real privacy page.
