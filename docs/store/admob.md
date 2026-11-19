# Fluxa: AdMob ids

Created 2026-11-19 in the Ecom Swift AdMob account (publisher `pub-8621573128492952`), through the owner's logged-in Chrome. No payment or tax data was entered.

| Item | Name in AdMob | Id |
|---|---|---|
| iOS app (not yet in the App Store, answered "No" to listed on a store) | Video Converter MP4 MKV: Fluxa | `ca-app-pub-8621573128492952~9759161163` |
| Banner ad unit | Fluxa Home Banner | `ca-app-pub-8621573128492952/5390551644` |
| Rewarded ad unit (reward: 1 Export) | Fluxa Export Rewarded | `ca-app-pub-8621573128492952/6076560319` |

- `Config/Release.xcconfig` holds these three ids (`ADMOB_APP_ID`, `ADMOB_BANNER_UNIT_ID`, `ADMOB_REWARDED_UNIT_ID`). `Config/Debug.xcconfig` keeps Google's public test ids. `.github/workflows/release.yml` refuses test ids in a release.
- AdMob app page: https://admob.google.com/v2/apps/9759161163/overview
- Status in AdMob: "Requires review, limited ad serving" until the App Store listing is linked. New units may take up to an hour to serve ads. After the app is live: AdMob > Apps > Fluxa > Add store.
- `app-ads.txt` already lists this publisher id at https://ecomswiftllc.github.io/app-ads.txt (shared by every app of the account, unchanged). Set the developer/marketing website of the App Store listing to https://ecomswiftllc.github.io/fluxa/ so Apple and AdMob can match it.
- Recommended in AdMob: maximum ad content rating General or Parental Guidance and block sensitive categories, to match the 4+ age rating.
- Policy reminders (HARD): the banner appears on Home only, never over the conversion controls or progress; the rewarded ad is opt-in with a clear prompt, one ad per export (a batch counts as one), and an export is free when no ad is ready.
