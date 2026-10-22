# Term Organize

An unofficial iPhone, iPad and Mac app for Northeastern University course search, schedule
building, degree planning and seat alerts — an on-device adaptation of
[SearchNEU](https://github.com/sandboxnu/searchneu) by [Sandbox](https://sandboxnu.com),
redesigned for iOS 26 and macOS 26 with Liquid Glass.

> Not affiliated with, endorsed by, or sponsored by Northeastern University or Sandbox.

## Highlights

- **Search everything** — courses by code (`cs3000`, `CS 3`), title, topic, professor or
  CRN, with typo tolerance and student shorthand (`orgo`, `linalg`, `fundies`, `ml`).
  Filter by subject, NUpath, level, credits, campus, class type, instruction mode, meeting
  days and times, honors and open seats.
- **Course pages** — descriptions, prerequisite/corequisite trees, “prerequisite for”,
  every section with instructors, meeting times, locations, seats and waitlists, refreshed
  live from Northeastern's registration system.
- **Schedule builder** — collect courses into plans, pick sections on a week calendar with
  conflict detection, or generate every conflict-free schedule with constraints (start/end
  times, free days, campus, seats…). Export to Calendar or `.ics`, share as an image, copy
  CRNs for registration.
- **Degree plans** — import the PDF from the degree audit planner's *View Plan* (or open it
  from Files/Mail with “Open in Term Organize”), see every semester with prerequisite
  checks, duplicate warnings and credit totals, edit it, and export it again as a PDF in the
  same layout. New plans start from your latest plan plus your “My Schedule” courses, and a
  new schedule autofills with the courses you planned for that semester (or the closest one
  you planned). Course pages mark completed prerequisites and show where a course is planned.
- **Degree requirements** — pick your catalog year, program and concentration, and the plan is
  checked against that year's requirements from Northeastern's academic catalog: every listed
  course with its status (completed, in progress, planned for a semester, or not in plan),
  "complete N of the following" lists, elective ranges and general electives, plus when you'll
  finish. Each course counts once, and the audit makes sure no other way of matching your
  courses to the requirements meets more of them (if every requirement can be met, it shows
  them met). Record course substitutions, petitions that replace a requirement (say, "two
  courses like the Khoury electives" — the app asks whether that requirement's minimum course
  number applies to your petition), and waivers; a course a short requirement's number range
  just misses can be counted with one tap once an adviser approves it. Topics courses taken
  twice count twice, and substitutions follow their requirement when you change catalog
  years. A substitution that is really a renumbered course (CS 3484 for the retired IS 4800)
  can become one, and then reads like any renumbered course. Requirements the catalog states
  in words are checked too: hours in the major, co-op, total hours, every NUpath requirement
  (from the NUpath attributes of each course's sections; one course counts for at most two of
  the eight areas) and the catalog year's Universitywide minimums. The GPA and residency, which
  a plan can't show, are marked as not checked. Catalog years and programs are read from the
  catalog site itself, so a new catalog year works without an app update. An unofficial
  planning aid; the registrar's audit is official.
- **Smarter prerequisite checks** — courses that aren't offered this term are checked against
  Banner's course catalog from earlier terms, and renumbered courses (say CS 2510 → CS 2100)
  can be marked as counting for each other, with suggestions taken from how prerequisites list
  them together.
- **Your ideal week** — tell the schedule generator what you want: preferred times of day,
  earliest start and latest finish, days off, no-go times (club meetings, work, commute),
  breaks and lunch, classes per day, walking time between buildings, format, campus and
  instructors — as a survey with presets, or by describing it in your own words, which Apple
  Intelligence turns into survey answers on the device for you to review. Schedules are ranked
  by how well they match, with the reasons shown. When nothing fits, the app names the courses
  in the way and, with a degree plan, suggests moving one to a semester it has historically been
  offered in.
- **Seat alerts** — watch full sections; background refresh + local notifications tell you
  when seats or waitlist spots open (SearchNEU uses SMS; this runs entirely on device).
- **Free rooms** — see which classrooms are empty right now (or at any time) and each
  room's weekly schedule.
- **Professors** — every instructor's sections and weekly teaching calendar.
- **Widgets** — “Up Next” (Home & Lock Screen) and a daily class agenda; an “Up Next”
  accessory above the tab bar.
- **Spotlight & Siri** — courses are indexed in Spotlight; App Shortcuts answer
  “What's my next class?”, open your schedule, or search courses.
- **Deep links** — `termorganize://course/202710/CS/3000`, `…/section/202710/<crn>`,
  `…/schedule`, `…/search?q=…`. Links from before the rename (`neuclasssearch://…`) still open.

## On the Mac

The Mac app shares everything but its interface with the iPhone and iPad app (the catalog,
search, schedules, degree plans and audit, seat alerts, iCloud sync) and is laid out the
Mac way:

- **One window, a sidebar** of areas (Search, Subjects, Saved, Professors, Free Rooms), the
  term's schedules, degree plans and the watchlist; the term menu sits in the toolbar.
- **Made for big screens**: every screen splits into panes you can resize by dragging the
  divider (double-click resets it; drag it all the way over to close the pane), and the panes
  keep their share as the window grows. A degree plan shows its requirements side by side
  (drag a course you still need onto a semester to plan it); schedules show as cards with
  their weeks, Free Rooms as a timeline of every room. Show or hide a screen's side pane with
  View › Show/Hide (⌥⌘0). In a small window, side panes float over the main view instead of
  making the window wider.
- **Tables** for search results, sections, watched sections and rooms — sortable columns,
  context menus, double-click or Return to open, Delete to remove, ⌘C to copy CRNs.
- **Course and professor windows** open side by side, from anywhere.
- **Menus and shortcuts**: New Schedule ⌘N, New Degree Plan ⇧⌘N, Import Degree Plan ⌘O,
  Export ⌘E, Print ⌘P, Reload ⌘R, the areas on ⌘1–⌘8, plus Schedule and Degree Plan menus.
- **Drag and drop**: drop a degree audit PDF on the window to import it, drag courses
  between semesters, drop course codes into a schedule.
- **Settings** (⌘,): General, Data, iCloud, Notifications and About (license, attribution
  and acknowledgements).
- **Up Next** in the menu bar: the class in progress or the next one, and today's classes.
- **Seat alerts** are checked every 15 minutes while the app is open (configurable).

## Runs fully on device

There is no backend. The app ships with compressed snapshots of the Fall 2026 and Spring 2027
catalogs (`NEUClassSearch/Resources/Catalog/term-202710.catalog`, ~0.9 MB, 3,103 courses /
8,472 sections, and `term-202730.catalog`, ~0.8 MB, 3,076 courses / 8,326 sections) so it
works offline instantly. With no term chosen yet, it opens the newest bundled term. When
online it talks **directly** to Northeastern's public Banner class search
(`nubanner.neu.edu`) to:

- refresh seats for a course when you open it (2 requests),
- download a whole term's sections (≈20 requests) — for a term that isn't bundled yet,
- lazily fetch descriptions, requisites and instructors for courses that aren't in the
  snapshot,
- look up the catalog entry (prerequisites, credits) of a course that isn't offered this term,
  which recent terms offered it, and the NUpath attributes of its sections (for the NUpath
  check),
- check watched sections for open seats.

For degree requirements it also reads Northeastern's public academic catalog
(`catalog.northeastern.edu`): the list of catalog years, the year's program index, your
program's page and the year's Universitywide Requirements page — fetched once per catalog year (the current year is re-checked weekly) and kept
on device. Nothing about you is sent to either site.

Your plans, degree plans, watchlist, bookmarks and preferences are stored as JSON in the
app's Application Support folder. With [iCloud sync](#icloud-sync) on, they are also kept in
your own private iCloud database so they sync between your devices; nothing is uploaded
anywhere else. Degree audit PDFs are read on device with PDFKit; the student name and ID
they contain are kept only if you choose to, never synced, and left out of exports unless
you include them.

## iCloud sync

Schedules, degree plans, the watchlist, saved courses and a few preferences sync between a
user's iPhone, iPad and Mac through **their private CloudKit database** (container
`iCloud.com.alexchadwick.neuclasssearch`). Only the user can read that database; the
developers can't. Each item's data is stored in CloudKit's end-to-end encrypted fields.
Settings › iCloud has a **Sync with iCloud** switch (on by default), the sync status and
**Sync now**.

| Syncs | Stays on the device |
| --- | --- |
| Schedule plans (courses, sections, filters, favorites, primary plan) | Recent courses and search history |
| Degree plans, requirements choices and substitutions | The student name and ID from an imported degree audit |
| Watched sections and their waitlist setting | Each device's seat checks and alerts (every device checks and notifies on its own) |
| Saved courses | The term being browsed |
| Preferred campus, calendar weekends and hours | Onboarding, auto-refresh and background-refresh settings |

How it works (`NEUClassSearch/Services/CloudSync/`):

- [`CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine) syncs
  one custom zone, `UserData`, with one record per item whose name is the item's id. Records
  carry `payload` (the item's JSON), `modifiedAt` and `schemaVersion`. Records written by a
  newer version of the app (a higher `schemaVersion`) or that can't be read are left alone,
  never overwritten or deleted.
- After each local save the app compares fingerprints of its data with what iCloud last
  confirmed and queues only what changed. Changes received from iCloud are never sent back.
- Conflicts: the most recent change wins (an item's own `updatedAt` where it has one,
  otherwise when it changed on the device); preferences merge setting by setting. An item
  deleted on one device is deleted everywhere, unless another device changed it since, in
  which case that version is kept.
- Accounts: on sign-in, the device's data is merged with the account's. Signing out keeps
  the data on the device and stops syncing. If a different Apple Account signs in, or the
  app's iCloud data is deleted in Settings, sync turns itself off (keeping the device's data)
  until the user turns it on again.
- **Erase all schedules, watchlist & bookmarks** in Settings also erases them from iCloud
  (and so from the user's other devices) while sync is on; the confirmation says so.
- Sync bookkeeping (CloudKit system fields, the engine's state) lives in
  `Application Support/CloudSync/`. Unit tests: `NEUClassSearchTests/CloudSyncTests.swift`.

To enable it in your build:

1. In Xcode, select the **NEUClassSearch** target › *Signing & Capabilities* and choose
   your development team (and the same team for `NEUClassSearchWidgets` and, for the Mac,
   `NEUClassSearchMac`).
2. The iCloud (CloudKit) and Push Notifications capabilities are already declared in
   `NEUClassSearchiOS/NEUClassSearch.entitlements` and
   `NEUClassSearchMac/NEUClassSearchMac.entitlements`, with the container
   `iCloud.com.alexchadwick.neuclasssearch`. With automatic signing, Xcode registers the
   container for your team the first time you build to a device (check the iCloud section
   of *Signing & Capabilities*). If you change the bundle identifier, change the container in
   the entitlements file and in Info.plist's `NEUCloudKitContainerIdentifier` key together.
3. Run the app on two devices signed in to the same Apple Account (iCloud turned on) and
   leave **Sync with iCloud** on. Changes usually arrive within seconds; the app also checks
   whenever it opens.
4. Before a TestFlight or App Store release, deploy the schema to production in
   [CloudKit Console](https://icloud.developer.apple.com) (development creates record types
   on first save). Xcode switches `aps-environment` to production when it exports for
   distribution.

A build without `NEUCloudKitContainerIdentifier`, or one whose signature lacks the iCloud
entitlements for the container, never touches CloudKit and shows "iCloud sync isn't set up
in this build". Without an iCloud account (as in a fresh simulator) it shows "Sign in to
iCloud in Settings to sync". Either way the app works as before.

## Requirements

- Xcode 27 (built and tested with Xcode 27.0 beta, 27A5218g); iOS 26.0+ and macOS 26.0+
  deployment targets.
- No third-party dependencies.

Run the unit tests (search engine, Banner parsers, schedule generator, degree plan
import/export, iCloud sync merging, models) with
⌘U in Xcode, or:

```bash
xcodebuild test -project NEUClassSearch.xcodeproj -scheme NEUClassSearch -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Open `NEUClassSearch.xcodeproj`, choose the **NEUClassSearch** scheme and run. For a
device build, set your development team under *Signing & Capabilities* for both the app
and the `NEUClassSearchWidgets` extension, and change the bundle identifiers / app group
(`group.com.alexchadwick.neuclasssearch`, also referenced in `TermOrganizeKit/Sources/TermOrganizeKit/Services/AppPaths.swift`
and `Shared/WidgetScheduleData.swift`) if needed.

For the Mac, choose the **NEUClassSearchMac** scheme. To build it without a development
team (no iCloud or push; everything else works), sign it to run locally with the sandbox
entitlements in `NEUClassSearchMac/NEUClassSearchMac-Local.entitlements`:

```bash
xcodebuild -project NEUClassSearch.xcodeproj -scheme NEUClassSearchMac -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=NEUClassSearchMac/NEUClassSearchMac-Local.entitlements build
```

## Local MCP server

`term-organize-mcp` is a local stdio server for the two catalogs bundled with the app
(Fall 2026 `202710` and Spring 2027 `202730`) and for the degree plans stored in
`UserData.json`. Schedules are listed separately and are not what the write tools edit.
It does not use the network. It is unofficial and not affiliated with
Northeastern University. Tool names, JSON shapes, the plan file, and the read-only
switch are in [`docs/MCP.md`](docs/MCP.md).

Build it with Swift 6.2 or newer (the package declares a macOS 26 deployment target):

```bash
cd TermOrganizeKit
swift build -c release
```

The `swift build` binary is `TermOrganizeKit/.build/release/term-organize-mcp`. Pass
`--read-only`, or set `TERM_ORGANIZE_MCP_READONLY=1`, to hide every tool that writes a
plan. `list_plans` and `get_plan` stay available.

A team-signed Mac app embeds the helper here, signed with team `832J6JB4V7` and the
group-only entitlements in `TermOrganizeKit/term-organize-mcp.entitlements`:

```
Term Organize.app/Contents/Helpers/term-organize-mcp
```

Point clients at that embedded binary. User script sandboxing stays on. The Xcode
target is `term-organize-mcp`. It links the TermOrganizeKit package product.

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "term-organize": {
      "command": "/ABSOLUTE/PATH/Term Organize.app/Contents/Helpers/term-organize-mcp"
    }
  }
}
```

Cursor (`.cursor/mcp.json` in this repo, or the user MCP config):

```json
{
  "mcpServers": {
    "term-organize": {
      "command": "/ABSOLUTE/PATH/Term Organize.app/Contents/Helpers/term-organize-mcp",
      "args": []
    }
  }
}
```

To start it read-only, add `"args": ["--read-only"]`.

Messages are one JSON object per line. There is no Content-Length header.

On a team-signed Mac, the app and this helper share the app group
`832J6JB4V7.com.alexchadwick.termorganize` (team `832J6JB4V7`). `UserData.json` lives in
that group container. Team signing does not need a separate portal registration step
for the group. The iOS widget group is unchanged. Only the Mac app copies the old
Application Support file into the group, keeps `UserData.json.premigration.bak`, and
deletes the original only after the copy matches. The helper never reads, moves, or
deletes the app container. If the group file is missing and that container file is
still there, plan tools return `storage_error` with the message "Open Term Organize
once to finish moving your plans". See [`docs/MCP.md`](docs/MCP.md).
If the app still has an unsaved edit when the file changes, the next flush merges plans
that were edited separately. Schedules that share a folder are one plan, so a conflict
keeps the file's version and one copy named "<plan> (edited in app)". The sidebar
badge says "App edit" and the visible label drops that suffix. The stored name keeps it.

Run the server tests with `cd TermOrganizeKit && swift test`. They use a temporary
`UserData.json` and never the real plans file.

## Regenerating the bundled catalog

```bash
Tools/build-catalog-snapshot.sh            # newest term Banner lists
Tools/build-catalog-snapshot.sh 202730     # a specific term (e.g. Spring 2027)
```

The script compiles a small command-line tool from `TermOrganizeKit/Sources/TermOrganizeKit/Core` and scrapes
the term the same way SearchNEU's scraper does (sections, instructors, descriptions,
requisites, catalog titles) with modest request concurrency. Instructor email addresses are
kept only when the domain is `northeastern.edu` or `neu.edu`. A full term takes about
20–25 minutes and writes `term-<code>.catalog` into `NEUClassSearch/Resources/Catalog/`.
On Linux, install a Swift toolchain and the [lzfse](https://github.com/lzfse/lzfse) reference
library; the script compiles with `swiftc` and compresses the JSON with `lzfse` into the
same LZFSE catalog the Mac build writes.

## Project structure

```
TermOrganizeKit/        Swift package: shared Foundation code and the local MCP server
  Package.swift
  Sources/TermOrganizeKit/
    Core/               Models, Banner client and parsers, catalog archive
    Logic/              Degree-plan and schedule logic shared with the apps
    Services/           Search, user models, UserData.json read and write
    MCP/                stdio server (excluded from the iOS and Mac app targets)
  Sources/TermOrganizeMCP/   term-organize-mcp executable
  Tests/TermOrganizeMCPTests/
NEUClassSearch/         App-only sources, compiled into both apps, plus resources
  Core/, Logic/, Services/   Sources that stay in the app (CloudKit, Spotlight, PDF, assistant)
  DesignSystem/         Theme, badges, Liquid Glass chips, week calendar, course rows
  Resources/            Asset catalog, app icon, catalog snapshots, license text
NEUClassSearchiOS/      iPhone and iPad interface
  App/                  App entry, root TabView, router and deep links (termorganize://)
  Features/             Home, Search, Course, Professors, Schedule, DegreePlan, Watchlist,
                        Rooms, Settings, Onboarding
NEUClassSearchMac/      Mac interface: sidebar window, course and professor windows, menu
                        commands, Settings, Up Next menu bar extra
NEUClassSearchWidgets/  WidgetKit extension (Up Next, Class Agenda)
Shared/                 Code compiled into the apps and the widgets
NEUClassSearchTests/    Swift Testing suites
Tools/                  Catalog snapshot tool and build script
docs/MCP.md             MCP tool names and JSON shapes
```

## License & attribution

Copyright (C) 2026 Term Organize contributors.
Source code: <https://github.com/AlexmChadwick/Northeastern-Term-Organize>.

Term Organize is free software, licensed under the **GNU Affero General Public License
v3.0 only** — see [`LICENSE`](LICENSE). It is distributed WITHOUT ANY WARRANTY; see the
license for details. It is a modified work based on SearchNEU
(© Sandbox at Northeastern University and the SearchNEU contributors, AGPL-3.0); see
[`NOTICE.md`](NOTICE.md) for exactly which parts were derived and how they were changed.
Course information © Northeastern University.
