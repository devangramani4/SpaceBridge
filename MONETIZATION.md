# SpaceBridge Pro — Business & Monetization Plan

**Company:** Genius Bridge Technologies · **Market:** United States · **Model:** Free app + Pro subscription

---

## 1. Product tiers

| | **Free** | **Pro — $99.99 / year** |
|---|---|---|
| Full-disk scan, dashboard, categories | ✓ | ✓ |
| Largest files (Top 10/50/100) and largest folders tree | ✓ | ✓ |
| Applications list (size, RAM, CPU) | ✓ | ✓ |
| Running apps, Memory and CPU monitors | ✓ | ✓ |
| Basic search (name, `*.zip`) | ✓ | ✓ |
| Cleanup recommendations (view) | ✓ | ✓ |
| **One-click cleanup** (move caches, DerivedData… to Trash) | — | ✓ |
| **Duplicate finder** | — | ✓ |
| **Developer Storage** (Xcode, node_modules, Docker, Android, Git) | — | ✓ |
| **Advanced search** (size, date, folder filters) | — | ✓ |
| **Top 500 / custom lists** | — | ✓ |
| **External and network drives** | — | ✓ |
| **Per-app storage breakdown** | — | ✓ |
| **CSV export** | — | ✓ |

- **14-day free trial** of everything. No card is needed; it starts from inside the app.
- The free tier stays genuinely useful. A good free product brings in downloads, reviews and word of mouth. Pro sells the time saved: users *see* the problem for free and *fix* it with Pro.

All feature gates live in `ProFeature` (`Services/LicenseService.swift`). To move a feature between tiers, change where `ProGate` or `requirePro` is used.

## 2. A frank note on the $99.99 price

US competitors, for reference:

| App | Price |
|---|---|
| CleanMyMac | about $40/year (or $90 one-time) |
| DaisyDisk | $10 one-time |
| iStat Menus | about $12/year |
| GrandPerspective, OmniDiskSweeper | free |

**$99.99/year is 2.5× the market leader.** It can work, but only if you sell to **developers and IT/business users**: Developer Storage, Docker and Xcode cleanup, CSV audit reports, and many Macs per company. Typical consumers will mostly choose CleanMyMac.

**Recommended:** keep $99.99 as the "Pro / Team" price, and test against these with Lemon Squeezy discount codes or a second variant:
- **Personal:** $29.99/year (or $49 lifetime)
- **Pro:** $99.99/year, for up to 3 Macs, with developer tools and export

Change prices in `ProConfiguration.priceText` and in your Lemon Squeezy product. Decide from real conversion numbers after 4–6 weeks.

## 3. How you get paid (set this up first)

SpaceBridge ships outside the Mac App Store (Developer ID). A full-disk analyzer can't be sandboxed, and Mac App Store apps can't get Full Disk Access. That means you can't use Apple In-App Purchase; you need a web checkout.

**Use a Merchant of Record: Lemon Squeezy (built in) or Paddle.** A merchant of record sells to the US customer for you. It:
- collects US **sales tax** for all states (a big legal burden otherwise),
- handles cards, Apple Pay, PayPal, refunds, chargebacks and invoices,
- pays you out to your Indian bank account (or via PayPal or Payoneer),
- charges about 5% + $0.50 per sale.

On $99.99 you keep roughly **$94.50** before your own income tax.

Steps:
1. Create a Lemon Squeezy store (`geniusbridge.lemonsqueezy.com`) and complete identity and payout verification.
2. Create the product **SpaceBridge Pro**: a subscription, $99.99 yearly, USD.
3. Enable **License keys** on the product, with an activation limit of 3 Macs. Lemon Squeezy then emails a key after each purchase and disables it automatically when the subscription ends or is refunded.
4. Put your real values in `SpaceBridge/Services/LicenseService.swift` → `ProConfiguration`:
   - `checkoutURL`: the product's share or checkout link
   - `customerPortalURL`: your store's billing portal
   - `storeID` and `productIDs`: from Settings ▸ Stores and the product page (this stops keys from other stores working)
   - `termsURL`, `privacyURL`, `supportEmail`
5. Test end to end in Lemon Squeezy **test mode** with a test card, then switch to live.

**How licensing works in the app** (`App/ProStore.swift`):
- **Activate:** the user pastes the key from their email. The app makes one HTTPS request to the Lemon Squeezy License API and stores the result in the macOS Keychain.
- **Re-check:** at most once every 7 days. If the Mac is offline, Pro keeps working for 30 days.
- **What's sent:** only the license key and a random instance ID. No file or system data, ever. The free version makes **no** network requests.
- **Deactivate:** "Deactivate This Mac" in Settings frees an activation so the key can move to a new Mac.

**Indian tax and compliance (talk to a CA):** export of software services is generally zero-rated for GST with an LUT. Report the income under your company, and keep the merchant-of-record payout statements.

## 4. Legal pages you need before launch (US customers)

Host these at `geniusbridge.com/spacebridge/…`:
- **Terms of Service / EULA:** subscription auto-renews yearly, cancel anytime, refund policy (I recommend a 14-day no-questions refund), license for up to 3 Macs, limitation of liability.
- **Privacy Policy:** state that file data never leaves the Mac, and that only the license key goes to Lemon Squeezy for Pro. This is your strongest selling point; make it prominent.
- **Auto-renewal disclosure:** several US states (e.g. California) require a clear renewal notice at checkout and an easy online cancellation. Lemon Squeezy's checkout and customer portal cover this; keep the "Billed yearly · Cancel anytime" text in the app.

## 5. Go-to-market in the US

**Website** (a single landing page is enough to start):
- Headline: "See what's eating your Mac's storage — privately."
- 30-second demo video, screenshots of the Dashboard and Developer Storage, a Download button (notarized DMG) and Pricing.
- Trust signals: "Works offline", "Notarized by Apple", "Nothing is deleted without asking".

**Channels**, in order of cost-effectiveness:
1. **Developers:** Hacker News "Show HN", r/macapps, r/iOSProgramming, r/webdev, Dev.to and Indie Hackers posts. Lead with "Find 50 GB of Xcode DerivedData, node_modules and Docker junk."
2. **Product Hunt launch:** prepare a gallery, video and a launch-day discount (e.g. 30% off the first year).
3. **SEO articles:** "How to clear System Data on Mac", "Delete Xcode DerivedData safely", "What is taking up space on my Mac". These are high-intent US searches.
4. **Setapp** (a subscription bundle of Mac apps, large US audience). It pays per usage and suits utilities well; you can list there in addition to direct sales.
5. **YouTube and newsletters:** send free Pro licenses to Mac YouTubers and to newsletters such as iOS Dev Weekly or Mac Power Users.
6. **Paid ads**, only after organic conversion is proven: Apple Search Ads doesn't apply outside the App Store, so use Google Search ads on "mac storage full" with a strict budget.

**In-app conversion** (already built):
- The trial is offered on every Pro screen. The sidebar "Upgrade to Pro" card turns into a trial countdown.
- Free Cleanup shows the reclaimable gigabytes with the action locked. This is the moment of highest intent.

## 6. Revenue model (example, not a forecast)

| Metric | Conservative | Good |
|---|---|---|
| Monthly downloads | 2,000 | 10,000 |
| Trial → paid | 3% | 5% |
| New Pro subscribers / month | 60 | 500 |
| Net per subscriber (after merchant fees) | $94.50 | $94.50 |
| New annual revenue added per month | ~$5,700 | ~$47,000 |
| Year-1 renewal rate | 55% | 70% |

Track three numbers weekly: downloads, trial starts and paid conversions. Lemon Squeezy's dashboard shows revenue, MRR and churn.

## 7. iPhone, iPad and Apple Watch

- **Sold through the App Store** with StoreKit subscriptions. Apple takes 15% under the Small Business Program (revenue below $1M) and handles US sales tax.
- **Recommended pricing:** US iPhone users pay much less for utilities than Mac users. Suggested: **$2.99/month or $19.99/year**, with a 1-week free trial set as an introductory offer in App Store Connect. $99.99/year on iPhone would convert very poorly.
- **Free:** storage overview, the top 10 largest videos and items, device monitor and tips. **Pro:** duplicates, screenshot cleanup, bulk delete, the Files scanner, full lists and the Watch glance.
- **App Store review notes:** explain that the Photos permission is used only for on-device size analysis, and that deletions go through iOS's own confirmation. Fill in the App Privacy label as **"Data Not Collected"**, which is accurate for this app.

## 8. Launch checklist

- [ ] Apple Developer Program ($99/year), Developer ID certificate, notarization (`scripts/release.sh`)
- [ ] Lemon Squeezy store live, product and license keys configured, `ProConfiguration` filled in
- [ ] Test purchase → email key → activate → deactivate → refund disables Pro
- [ ] Terms, Privacy and Refund pages live; support email monitored
- [ ] Landing page with notarized DMG download
- [ ] Product Hunt, HN and Reddit launch week
- [ ] Optional: Sparkle auto-updates (adds an update check; mention it in the Privacy Policy)
