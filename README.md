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

## Features

Everything below is in the source on `main`. The path is where to start reading.

- **Search, with an All / Undergrad / Grad filter.** Undergrad is a course number below 5000. Grad is 5000 and above. The rule is `DegreeLevelFilter` in `TermOrganizeKit/Sources/TermOrganizeKit/Services/SearchEngine.swift`. The control is `DegreeLevelFilterPicker` in `NEUClassSearch/DesignSystem/Components/CreditChoiceControl.swift`, used by `NEUClassSearchiOS/Features/Search/SearchFilterBar.swift` and `NEUClassSearchMac/Catalog/MacSearchFilterBar.swift`. Search matches codes, titles, instructors, and CRNs. It expands student shorthand (`SearchText.aliases`: `orgo`, `linalg`, `fundies`, `ml`, and the rest of that table) and allows small typos (`SearchText.editDistance`). `SearchFilters` in the same file also covers subject, NUpath, level, credits, campus, class type, instruction mode, meeting days and times, honors, and open seats.
- **Schedules.** Collect courses, pick sections, and generate ranked conflict-free options (`TermOrganizeKit/Sources/TermOrganizeKit/Logic/Schedule/ScheduleGenerator.swift`, `NEUClassSearchMac/Schedules/`, `NEUClassSearchiOS/Features/Schedule/`). Time, day, and campus preferences live in `TermOrganizeKit/Sources/TermOrganizeKit/Logic/Schedule/SchedulePreferences.swift`. A written description of the week can be filled into that survey on device with Apple Intelligence (`NEUClassSearch/Logic/Schedule/ScheduleAssistant.swift`, `NEUClassSearchiOS/Features/Schedule/SchedulePreferencesView.swift`).
- **Calendar export.** A plan can be added to Calendar or shared as `.ics`. The Mac sheet can also save a picture (`NEUClassSearch/Logic/Schedule/ScheduleExporter.swift`, `NEUClassSearchMac/Schedules/MacScheduleExport.swift`, `NEUClassSearchiOS/Features/Schedule/ScheduleExportViews.swift`).
- **Degree plans and an unofficial audit.** Import a degree-audit View Plan PDF, edit the semesters, and export a PDF in that layout (`TermOrganizeKit/Sources/TermOrganizeKit/Logic/DegreePlan/DegreePlanFormat.swift`, `NEUClassSearchMac/DegreePlans/MacDegreePlanImportSheet.swift`, `NEUClassSearchMac/DegreePlans/MacDegreePlanExportSheet.swift`, and the matching files under `NEUClassSearchiOS/Features/DegreePlan/`). Both apps register PDF as a document type in their `Info.plist`. Requirements for a catalog year and program are checked in `TermOrganizeKit/Sources/TermOrganizeKit/Logic/DegreePlan/DegreeAudit.swift`. NUpath handling is in `DegreeNUpath.swift`: one course counts for at most two of the eight areas. GPA and residency stay unchecked, because a plan has no grades and does not say where the credits were earned. Substitutions and petitions can be recorded. The requirements screen says: "Unofficial planning aid. Confirm with your degree audit and academic advisor." (`NEUClassSearchiOS/Features/DegreePlan/DegreeRequirementsView.swift`, `NEUClassSearchMac/DegreePlans/MacDegreeRequirementsView.swift`).
- **Variable credits.** When the low and high credit values differ, a stepper sets a whole-credit value inside that range (`CreditSpan` in `TermOrganizeKit/Sources/TermOrganizeKit/Core/Models/VariableCredits.swift`, `CreditChoiceControl` in `NEUClassSearch/DesignSystem/Components/CreditChoiceControl.swift`).
- **CPS restriction note.** A section limited to College of Professional Studies students is captioned "Restricted to CPS (College of Professional Studies) students". If only some sections are, the caption is "Some sections are CPS only" (`CPSNote` in `TermOrganizeKit/Sources/TermOrganizeKit/Core/Models/SectionRestriction.swift`).
- **Seat status.** Seats are remaining versus capacity. None left reads "Full". The color is red when none remain, orange when few remain, and green otherwise (`Theme.seatColor` in `NEUClassSearch/DesignSystem/Theme.swift`, `SeatsBadge` in `NEUClassSearch/DesignSystem/Components/Badges.swift`). A section counts as open when `seatsRemaining > 0` (`CourseSection.isOpen` in `TermOrganizeKit/Sources/TermOrganizeKit/Core/Models/CourseSection.swift`). Waitlist counts are shown when Banner sends them (`SeatsBadge`, `NEUClassSearchMac/Catalog/MacSectionCells.swift`).
- **Watchlist and local notifications.** A watched section notifies when it goes from no seats to some seats. If "also notify on waitlist" is on, a still-full section can also notify when a waitlist spot appears (`TermOrganizeKit/Sources/TermOrganizeKit/Logic/Watchlist/WatchlistComparison.swift`, `NEUClassSearch/Logic/Watchlist/WatchlistService.swift`, `NEUClassSearch/Logic/Watchlist/WatchlistNotifications.swift`). On Mac, while the app is open, the default gap is 15 minutes. Settings offers 5, 10, 15, 30, or 60 (`NEUClassSearchMac/Shell/MacWatchlistMonitor.swift`). On iPhone and iPad the app asks iOS for a background check in about 20 minutes (`WatchlistService.backgroundRefreshInterval`). The watchlist screen says checks run about every 30 minutes when iOS allows (`NEUClassSearchiOS/Features/Watchlist/WatchlistTabView.swift`).
- **iCloud sync.** Schedules, degree plans (without the student name and ID), the watchlist (without each device's own seat-check results), saved courses, and a few preferences sync in the user's private CloudKit database. The container is `iCloud.com.alexchadwick.neuclasssearch` (`NEUCloudKitContainerIdentifier` in `NEUClassSearchiOS/Info.plist` and `NEUClassSearchMac/Info.plist`). What syncs is written down in `NEUClassSearch/Services/CloudSync/CloudSyncModel.swift`. Preferred campus, weekend columns, and calendar hours sync (`CloudSyncedPreferences`). The term being browsed, onboarding, auto-refresh, background refresh, recent courses, and search history stay on the device.
- **Keyboard list navigation on the Mac.** Up and down arrows move the highlight in Add Course (`NEUClassSearchMac/Schedules/MacAddCourseView.swift`, `NEUClassSearchMac/DegreePlans/MacDegreePlanAddCourse.swift`). Arrow keys also move through schedule cards, generated schedules, and degree-plan cards (`NEUClassSearchMac/Schedules/MacScheduleCards.swift`, `NEUClassSearchMac/Schedules/MacScheduleGenerator.swift`, `NEUClassSearchMac/DegreePlans/MacDegreePlanCards.swift`). Search results are a table: Return opens the selection (`NEUClassSearchMac/Catalog/MacCatalogCourseTable.swift`). The Go menu is Command-1 through Command-8 (`NEUClassSearchMac/Shell/MacCommands.swift`).

Also on `main`:

- **Free rooms.** `TermOrganizeKit/Sources/TermOrganizeKit/Logic/Rooms/RoomAvailability.swift`, `NEUClassSearchMac/Shell/MacRoomsView.swift`, `NEUClassSearchiOS/Features/Rooms/RoomsTabView.swift`.
- **Professors.** `TermOrganizeKit/Sources/TermOrganizeKit/Logic/Professors/ProfessorDirectoryData.swift`, `NEUClassSearchMac/Catalog/MacProfessorsView.swift`, `NEUClassSearchiOS/Features/Professors/ProfessorsDirectoryView.swift`.
- **Widgets.** Up Next and a daily agenda (`NEUClassSearchWidgets/UpNextWidget.swift`, `NEUClassSearchWidgets/TodayScheduleWidget.swift`).
- **Spotlight and shortcuts.** Courses are indexed for Spotlight (`NEUClassSearch/Services/SpotlightIndexer.swift`). App Shortcuts answer the next class, open the schedule, or search courses (`NEUClassSearchiOS/Features/Intents/ClassSearchIntents.swift`).
- **Links.** `termorganize://course/<term>/<subject>/<number>`, `termorganize://section/<term>/<crn>`, `termorganize://schedule`, and `termorganize://search?q=...`, plus the older `neuclasssearch://` scheme (both schemes are in each app's `Info.plist`). iOS routing is `NEUClassSearchiOS/App/AppRouter.swift`. On the Mac, a course link opens a course window (`NEUClassSearchMac/App/MacRootView.swift`). Schedule, watchlist, plan, and search links go through `NEUClassSearchMac/App/MacNavigation.swift`. A seat-alert section link opens that course (`NEUClassSearchMac/Shell/MacShell.swift`).
- **Offline catalogs.** Fall 2026 is `NEUClassSearch/Resources/Catalog/term-202710.catalog`. Spring 2027 is `term-202730.catalog` in the same folder.
- **Local MCP helper.** `term-organize-mcp` is a stdio server in `TermOrganizeKit` for the bundled catalogs and for degree plans in `UserData.json`. Tool names are in [`docs/MCP.md`](docs/MCP.md).
