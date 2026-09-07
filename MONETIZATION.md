# Before dotMD can be sold

Status as of 2026-09-07. dotMD itself is a feature-complete prototype; everything below is what's
missing between "works on my Mac" and "a stranger can pay for it and trust it."

## Legal / compliance
- [x] Pick a license — done, `LICENSE` (proprietary, matching Switchboard/TrafficControl). Still need the separate end-user EULA for a distributed binary.
- [ ] Write a short privacy policy (even "this app makes no network calls" is enough — required by
      Stripe/Lemon Squeezy/Gumroad checkout, and by users)
- [ ] Basic Terms of Sale / refund policy

## Distribution mechanics
- [x] Git version control — done (this repo)
- [ ] Enroll in the Apple Developer Program ($99/yr) if not already enrolled — you need a
      **Developer ID Application** cert, not the "Apple Development" one `build.sh` uses now
- [ ] Update `build.sh` to sign with the Developer ID cert instead of the ad-hoc/dev identifier
- [ ] **Notarize** the app (`xcrun notarytool submit` + `xcrun stapler staple`) — without this,
      paying users hit a hard "unidentified developer" block, not just a warning
- [ ] Package as a `.dmg` or `.zip` for distribution (not a loose `.app`)
- [ ] Add an auto-update mechanism (Sparkle is the standard) so fixes can ship without manual
      reinstalls

## Basic hygiene
- [ ] Add at least smoke tests for core flows (open file, edit in both panes, save, format menu)
- [ ] Add crash/error reporting (e.g. Sentry) so you find out when a paying user's install breaks
- [ ] Resolve the last open TODO item (stale SourceKit diagnostics) — not launch-blocking, but
      worth clearing before onboarding outside contributors

## Store listing basics
- [ ] Screenshots + short description + system requirements (macOS 14+)
- [ ] App icon — already exists, reuse it (`Resources/AppIcon.icns`)

## Pricing
dotMD competes indirectly with Typora ($15 one-time), iA Writer (~$30-50), Bear (~$30/yr) — it's a
daily-use editor, so $5 is on the low end. **$8-10** is defensible at launch; starting lower to
build reviews/momentum and raising the price later is also fine.

## How to actually monetize (step by step)
1. **Pick a merchant-of-record checkout**: Lemon Squeezy or Gumroad — they handle payment
   processing and EU VAT/sales tax and give you a hosted checkout + file delivery, so you don't
   need to touch Stripe directly or write license-key logic.
2. **Upload the notarized `.dmg`** as the deliverable file on the product page.
3. **Decide on enforcement**: simplest is *none* — trust-based, like most indie Mac tools. If you
   want light protection later, a license-key field validated against Lemon Squeezy's free license
   API is enough; don't over-engineer this for a $5-10 utility.
4. **Landing page**: one simple page with screenshots, a feature list, system requirements, and a
   "Buy" button linking to checkout — no full marketing site needed.
5. **Launch channels**: r/macapps, Hacker News "Show HN," Product Hunt.
6. **Aftercare**: once there are paying users, the auto-update mechanism and crash reporting above
   stop being optional.

---
This is the dotMD-specific slice of the shared cross-app plan at
`/Users/Marcus/Desktop/Dev/monetization-checklist.md` (also covers Switchboard, TrafficControl).
