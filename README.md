# Term Organize

**Term Organize is unofficial. It is not affiliated with or endorsed by Northeastern University.**

The same notice is in the app (`LegalText.unofficialNotice` in `TermOrganizeKit/Sources/TermOrganizeKit/Logic/Settings/LegalText.swift`): "Not affiliated with, endorsed by, or sponsored by Northeastern University or Sandbox."

Term Organize is a course planner for iPhone, iPad, and Mac. It searches Northeastern's public class listings, builds schedules, checks a degree plan, and watches seats. It is free software under the GNU Affero General Public License v3.0 only. Parts of the Banner parsing, requisite logic, and schedule generation are adapted from [SearchNEU](https://github.com/sandboxnu/searchneu) by Sandbox. See [`NOTICE.md`](NOTICE.md).

Class data comes from Northeastern's public Banner class search. `BannerClient.baseURL` in `TermOrganizeKit/Sources/TermOrganizeKit/Core/Banner/BannerClient.swift` is `https://nubanner.neu.edu/StudentRegistrationSsb/ssb/`. Degree-requirement pages are read from the public catalog at `catalog.northeastern.edu` (`TermOrganizeKit/Sources/TermOrganizeKit/Services/ProgramCatalogRepository.swift`).

## Version

The Xcode project marketing version is **1.1.3**, build **5** (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `NEUClassSearch.xcodeproj/project.pbxproj`). That matches the latest GitHub release, [v1.1.3](https://github.com/AlexmChadwick/Northeastern-Term-Organize/releases/tag/v1.1.3) (9 November 2026). The asset is [`Term-Organize-1.1.3-5.zip`](https://github.com/AlexmChadwick/Northeastern-Term-Organize/releases/download/v1.1.3/Term-Organize-1.1.3-5.zip).

SHA-256 of that zip, from the release notes:

```
39fc6b6fee3e5508c90cf309e2a1eee56da0b8c12b98f19660418c099f88ab68
```

The v1.1.3 release notes say the zip is Developer ID signed and notarized. The project sets `DEVELOPMENT_TEAM` to `832J6JB4V7`.

This repository's published release is the Mac app. iPhone and iPad builds come from the Xcode project. There is no App Store metadata in this repository.

## Install the Mac app

1. Download `Term-Organize-1.1.3-5.zip` from the [v1.1.3 release](https://github.com/AlexmChadwick/Northeastern-Term-Organize/releases/tag/v1.1.3). Later Mac builds, if any, are on the [Releases page](https://github.com/AlexmChadwick/Northeastern-Term-Organize/releases).
2. Unzip it and drag **Term Organize** into Applications.
3. Open it. The release notes say the notarized build opens without extra steps.
