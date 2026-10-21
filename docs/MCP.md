# Term Organize MCP server

Unofficial and not affiliated with Northeastern University.

`term-organize-mcp` speaks [MCP](https://modelcontextprotocol.io) over stdin and stdout.
It reads only the Fall 2026 (`202710`) and Spring 2027 (`202730`) catalogs bundled with
the app. It does not open a network connection and it does not log in.

The same tool names and JSON shapes are the contract for the Mac, Windows, and Linux
servers. A tool result has `content` (one text block of JSON), `structuredContent`
(the same object), and `isError`.

Build and client snippets are in the README section [Local MCP server](../README.md#local-mcp-server).

## Shared contract

- Transport: stdio, newline-delimited JSON-RPC 2.0, one message per line, per the MCP stdio spec (protocol 2025-06-18). No Content-Length framing.
- Term objects: {"term":"202730","name":"Spring 2027"}. The key is always "term", never "code".
- Revisions: integer, starting at 1 and incremented on every change to that plan.
- Errors: a tool result with isError:true and structuredContent {"error":{"code":C,"message":M}}, where C is one of: invalid_argument, not_found, revision_conflict, confirm_required, read_only, storage_error, unknown_tool. The message is never empty. A write tool called with --read-only on returns read_only, not unknown_tool. Write tools stay hidden from tools/list.
- Instructors in get_course: [{"name":..., "email":... (optional)}]. The email is present only when its domain is EXACTLY northeastern.edu or neu.edu, compared case-insensitively. Subdomains are not allowed (husky.neu.edu, ccs.neu.edu, mail.neu.edu are all dropped).
- create_plan {name, terms?: ["202710","202730"]}, a list of term strings.
- reorganize_plan accepts either {plan_id} or {plan:{terms:[{term, courses:[{subject, number, crn?}]}]}}. It returns {moves:[{subject, number, crn?, from_term, to_term, reason}], unresolved:[{subject, number, crn?, reason}], plan:{...}}.
- Reorganize rule, the same everywhere: a course moves only into a term the plan already has. The target term's bundled catalog must offer the course, prerequisite order within the plan must be kept, and it never adds a semester. An unpinned course is offered in a term when that term has at least one section of its subject and number. A course with a crn is offered only when that CRN is a section of it in that term. Two rows with different CRNs are different sections, even when they share a subject and number. Two unpinned rows of the same number collapse to the first.
- Duplicate course numbers: a saved term may contain the same subject and number more than once only when every row has its own crn and the crns differ. add_course without a crn does not create a second row. The same crn twice is not stored. set_section changes one row and does not clear another row's crn. suggest_schedule does not merge two such rows.
- Shared fixture: tests/fixtures/mcp-reorganize-fixture.json. It is a plan with CS 4805, CS 2535, CS 2700, CS 4130 and CS 2701 in Fall 2026, plus an empty Spring 2027. Each server must have a test that checks its output against the expected moves. Work out the expected result from the bundled 202730 catalog and the prereqs, and write it into the fixture. Include in your report the per-course reasoning: offered in 202730 yes/no, and prereq status.
- Storage failures: if the plan file exists but can't be read (permission denied, sandbox, malformed JSON, unknown newer version), every plan tool returns storage_error with the path and reason. NEVER treat a read failure as an empty plan list, and NEVER write over a file you couldn't read. A missing file is the only case that counts as empty.

## Catalog location

The server loads `term-202710.catalog` and `term-202730.catalog` in this order:

1. `TERM_ORGANIZE_CATALOG_DIR`, when it is set.
2. `Contents/Resources` next to an embedded helper at `Term Organize.app/Contents/Helpers/term-organize-mcp` (a `Catalog` folder under Resources counts too).
3. `NEUClassSearch/Resources/Catalog`, walking up from the current directory, the executable, and the app bundle. That is how the `swift build` binary finds the repo catalogs.

Any other term code is rejected. The tool error code is `invalid_argument`.

## Saved plans

Plans are not stored in SwiftData. The Mac app writes one JSON file, `UserData.json`,
through `UserDataStore`. Each schedule is a `SchedulePlan`: a name, one `termCode`,
the courses, the chosen CRNs, and timestamps. `UserDataStore` loads that file with
`UserDataFile.read` and writes it with `UserDataFile.writeResolvingConflicts`.

### Where the file lives

Team `832J6JB4V7` shares one app group between the sandboxed Mac app and the MCP helper:

```
832J6JB4V7.com.alexchadwick.termorganize
```

`UserData.json` is stored in that group container:

```
~/Library/Group Containers/832J6JB4V7.com.alexchadwick.termorganize/Library/Application Support/UserData.json
```

The Mac entitlements are `NEUClassSearchMac/NEUClassSearchMac.entitlements` and
`NEUClassSearchMac/NEUClassSearchMac-Local.entitlements`. Both list that group and
keep the app sandbox. The helper entitlement file is
`TermOrganizeKit/term-organize-mcp.entitlements`. It lists the same group and does
not turn on the app sandbox.

The helper is an Xcode command-line tool target named `term-organize-mcp`. It links
the TermOrganizeKit package product and compiles `TermOrganizeKit/Sources/TermOrganizeMCP/main.swift`.
A Mac app build embeds the signed binary at:

```
Term Organize.app/Contents/Helpers/term-organize-mcp
```

It is signed with team `832J6JB4V7` and the group-only entitlements. User script
sandboxing stays on. A team-signed build does not need a separate portal registration
step for this group. The bundle id is `com.alexchadwick.termorganize.mcp`.

The iOS app and the widgets keep `group.com.alexchadwick.neuclasssearch`. That
container is the widget snapshot (`WidgetSchedule.json`) only. It is not the plans file.

Only the Mac app migrates, and only from `UserDataStore` into the real group file.
The legacy location is the sandboxed app's own Application Support
(`FileManager.urls(for: .applicationSupportDirectory)`). Inside the sandbox that is:

```
~/Library/Containers/com.alexchadwick.neuclasssearch/Data/Library/Application Support/UserData.json
```

`homeDirectoryForCurrentUser` is already the container (`…/Data`), so the path does
not append `Library/Containers/…` a second time. The copy is
`UserData.json.premigration.bak` beside the original, and it is not overwritten. The
original is deleted only after the group copy's bytes match. An unreadable original
is left in place. If the group file already exists, the old file is left alone.
`TERM_ORGANIZE_USER_DATA` overrides the path and skips that copy. Tests set it and
never touch a real plans file.

The helper never reads, moves, or deletes the app container. If the group file is
missing and the container file exists, every plan tool returns `storage_error` with
the message "Open Term Organize once to finish moving your plans". The helper detects
that file with a stat only. If both files are missing, the plans are empty. A
sandboxed Mac build that does not have the group keeps `UserData.json` in its own
Application Support directory and does not migrate. The next team-signed launch
copies that container file into the group.

Writes take an exclusive lock (`UserData.json.lock`), copy the previous file to
`UserData.json.bak` (one rolling backup), write a temp file in the same directory,
and `rename` it over `UserData.json`. That backup is separate from the premigration
backup. A read failure does not create either write.

The app watches `UserData.json` with a file source and reloads it when the bytes
change, including while the window is already active. Becoming active reloads too.
A reload waits if the app still has an edit that has not been written. That flush
does not replace a file it could not read. It compares the file with the last load,
using each plan's revision and a SHA-256 of the bytes (a new modification time counts
only when the bytes changed too). Plans edited on different sides are combined.
When both sides edited the same plan, the file's version stays and the app's
version is saved beside it as "<plan> (edited in app)". Schedules that share a
folderID are one plan: one copy, one name, and no extra " 2" on a later term. An
MCP write is not dropped. The stored name keeps " (edited in app)". The Mac sidebar
and schedule lists show an "App edit" badge and drop that suffix from the visible
label, then middle-truncate what remains.

### Degree plans are the plans

`list_plans`, `get_plan`, and every write tool use `degreePlans` in `UserData.json`
("True Plan", "Summer Internship"). A semester is a Banner code plus the name the
degree plan already shows, for example `{"term":"202730","name":"Spring 2027"}`.
Fall of calendar year Y is `(Y+1)10`, Spring is `Y30`, Summer Session A is `Y40`,
Summer Full is `Y50`, Summer Session B is `Y60`, and Winter is `Y20`.

Schedules ("Plan A") stay in the file. `list_plans` returns them under `schedules`,
with the same term, `updated_at`, and revision fields. `get_plan` and the write
tools do not accept a schedule id. A schedule the app saved with no `folderID` is
one entry. Schedules that share a `folderID` are one entry, and the id is that
folder. Both `folderID` and a schedule's `revision` are optional, so an older
`UserData.json` still decodes. A missing schedule revision and a stored `0` both
count as `1` in that list. A `version` above `1` is an unknown newer file: every
plan tool returns `storage_error` and nothing is written.

Every write except `create_plan` requires `expected_revision`. The saved revision is
the degree plan's `revision`. A missing revision and a stored `0` both count as
`1`. If it does not match, the tool returns `revision_conflict` and does not write.
A successful write sets that degree plan's `revision` to `expected_revision + 1`.
New plans start at revision `1`.

A course is accepted when it exists in either bundled catalog, so a course that is
not taught in the target term can still be saved (that is what reorganize moves).
A CRN, when one is sent, must exist in the requested term and must belong to that
course. Unknown courses and CRNs are rejected and nothing is written.

## Read-only mode

`--read-only`, or `TERM_ORGANIZE_MCP_READONLY=1`, omits every tool whose
`readOnlyHint` is false from `tools/list`. `list_plans` and `get_plan` stay.
Calling a hidden write tool returns `read_only`, not `unknown_tool`.

## Annotations

Every tool sets `openWorldHint` to false. `readOnlyHint` is true for the catalog
tools and for `list_plans` and `get_plan`. `destructiveHint` is true for
`delete_plan`, `remove_course`, and `apply_reorganize`.

## Catalog tools

### `list_terms`

No arguments.

```json
{
  "terms": [
    { "term": "202730", "name": "Spring 2027" }
  ]
}
```

### `search_courses`

Required: `term`. Optional: `query`, `subject`, `number`, `attribute`, `limit`
(1 to 100, default 25).

```json
{
  "term": "202730",
  "courses": [
    {
      "subject": "CS",
      "number": "3000",
      "title": "Algorithms",
      "credits": { "min": 4, "max": 4 },
      "attributes": ["NCFQ"]
    }
  ]
}
```

### `get_course`

Required: `term`, `subject`, `number`.

Instructors are `[{"name": "...", "email": "..."}]`. `email` is present only when
its domain is exactly `northeastern.edu` or `neu.edu`, compared case-insensitively.
The local part is left as it was written. Subdomains are dropped.

### `check_schedule`

Required: `term`, `crns` (array of strings).

```json
{
  "term": "202730",
  "clashes": [
    { "crn": "2001", "other": "2003", "reason": "Overlapping meeting" }
  ],
  "unknown_crns": ["99999"]
}
```

### `suggest_schedule`

Required: `term`, `courses` (`[{ "subject", "number", "crn"? }]`). Optional `constraints`:

| Field | Notes |
| --- | --- |
| `no_classes_before` | `HH:MM`, 24-hour. Classes must start at or after this time. |
| `no_classes_after` | `HH:MM`. Classes must end at or before this time. |
| `days_off` | Array of `sunday` through `saturday`. |

Returns up to 8 conflict-free combinations, best score first. A course with no
sections in that term returns `not_found` (it has no sections in that bundled term).
When a course includes `crn`, every combination uses that section. The tool does
not replace it with another section of the same subject and number, even when the
pin conflicts or fails a constraint. A `crn` that belongs to a different course
returns `not_found`. A `crn` the catalog no longer lists keeps that row locked:
`sections` for it are empty, `schedules` does not substitute another section, and
the response includes `unavailable` as `[{ "subject", "number", "crn" }]`. Two
entries with the same subject and number and different `crn` values are two
courses. The generator does not merge them.

```json
{
  "term": "202730",
  "schedules": [
    {
      "crns": ["2002", "2004"],
      "score": 0,
      "sections": []
    }
  ]
}
```

`sections` uses the section object from `get_course`.

### `reorganize_plan`

Does not save. Pass either `plan_id` or:

```json
{
  "plan": {
    "terms": [
      { "term": "202710", "courses": [{ "subject": "CS", "number": "3500" }] },
      { "term": "202730", "courses": [{ "subject": "CS", "number": "3000" }] }
    ]
  }
}
```

A course moves only into a term the plan already has. An unpinned course moves
only when that term's bundled catalog has at least one section of its subject and
number. A course with `crn` moves only when that CRN is a section of it in the
target term. Another section of the same number does not count. Two such pins are
not collapsed into one row. Prerequisites that are also in the plan must sit in a
strictly earlier term (`202710` before `202730`). A prerequisite that is not in
the plan does not block the move. Tests do not block the move. Corequisites are
ignored. The tool does not add a semester, and it does not drop an empty term.
This is separate from the app's degree-plan reorganize. The returned course
object includes `crn` when the input had one.

```json
{
  "moves": [
    {
      "subject": "CS",
      "number": "3500",
      "from_term": "202710",
      "to_term": "202730",
      "reason": "Not offered in 202710. 202730 offers it, and prerequisites that are in this plan stay in an earlier term."
    }
  ],
  "unresolved": [],
  "plan": {
    "terms": [
      { "term": "202710", "courses": [] },
      { "term": "202730", "courses": [{ "subject": "CS", "number": "3000" }, { "subject": "CS", "number": "3500" }] }
    ]
  }
}
```

The shared fixture `tests/fixtures/mcp-reorganize-fixture.json` is the check for the
bundled catalogs. All five Fall 2026 courses in that file move to Spring 2027.
None of them have a section in `202710`. Each has at least one section in `202730`.
Their prerequisites are not in the plan, so order is kept. `unresolved` is empty.

## Plan tools

`updated_at` is an ISO-8601 timestamp. `revision` is an integer starting at 1.
A missing revision and a stored 0 are both reported as 1.

### `list_plans`

No arguments. Read-only. A missing file returns `{ "plans": [], "schedules": [] }`.
A file that exists but cannot be read returns `storage_error`. `plans` are degree
plans. `schedules` are the app's term schedules and are not writable through these
tools.

```json
{
  "plans": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
      "name": "True Plan",
      "terms": [
        { "term": "202710", "name": "Fall 2026" },
        { "term": "202730", "name": "Spring 2027" }
      ],
      "updated_at": "2026-10-20T19:00:00Z",
      "revision": 1
    }
  ],
  "schedules": [
    {
      "id": "7C9E6679-7425-40DE-944B-E07FC1F90AE7",
      "name": "Plan A",
      "terms": [
        { "term": "202730", "name": "Spring 2027" }
      ],
      "updated_at": "2026-10-20T19:00:00Z",
      "revision": 1
    }
  ]
}
```

### `get_plan`

Required: `plan_id` (UUID). Read-only.

```json
{
  "id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
  "name": "Spring",
  "revision": 1,
  "updated_at": "2026-10-20T19:00:00Z",
  "terms": [
    {
      "term": "202730",
      "name": "Spring 2027",
      "courses": [
        {
          "subject": "CS",
          "number": "3000",
          "crn": "2002",
          "sections": []
        }
      ]
    }
  ],
  "validation": {
    "clashes": [
      { "term": "202730", "crn": "2001", "other": "2003", "reason": "Overlapping meeting" }
    ],
    "not_offered": [
      { "term": "202710", "subject": "CS", "number": "3500" }
    ]
  }
}
```

Each object in `courses` is one row. `crn` is that row's chosen section, and
`sections` is that section. Two rows may share a subject and number when their
`crn` values differ. `sections` is empty when no CRN is chosen. `not_offered`
lists courses that have no sections in that bundled term. `clashes` lists chosen
sections whose meetings overlap.

`create_plan`, `rename_plan`, `add_course`, `remove_course`, `move_course`, and
`set_section` return this same object.

### `create_plan`

Required: `name`. Optional: `terms`, a list of term strings such as `"202710"` and
`"202730"`. Courses are not accepted here. Add them with `add_course`. With no
`terms`, the plan has one empty schedule on the newest loaded bundled term (`202730`
when that catalog loaded). The new revision is `1`. An object in `terms` is
`invalid_argument` and nothing is written.

### `rename_plan`

Required: `plan_id`, `name`, `expected_revision`.

### `add_course`

Required: `plan_id`, `term`, `subject`, `number`, `expected_revision`. Optional: `crn`.
Creates the term on the plan if it is not there yet.

The same subject and number may be added again only when `crn` is set, every row
of that number already has its own `crn`, and the new `crn` is different. Without
`crn`, a number already in the term is left as it is. Passing a `crn` when the
only row has none stores that `crn` on the existing row and does not add a second
row. The same `crn` twice does not add a row.

### `remove_course`

Required: `plan_id`, `term`, `subject`, `number`, `expected_revision`. Optional: `crn`.
Destructive.

This removes one row. When the term has one row of that subject and number, `crn`
can be omitted and that row is removed. When it has more than one, `crn` names the
row. Omitting it then is `invalid_argument` and nothing is written. A `crn` that is
not on a row of that number is `not_found` and nothing is written. The other rows
stay. An emptied extra term is removed. The last remaining term is kept so the plan
id still resolves.

### `move_course`

Required: `plan_id`, `subject`, `number`, `from_term`, `to_term`, `expected_revision`.
The course must already be in `from_term`. Every row of that subject and number
moves. A chosen CRN stays on its row only when that same CRN is a section of the
course in `to_term`. A row whose CRN is not offered there moves without a CRN, and
a missing CRN does not create a second row when `to_term` already has that number.

### `set_section`

Required: `plan_id`, `term`, `subject`, `number`, `crn`, `expected_revision`.
Optional: `from_crn`.

The course must already be in that term. This changes one row. When the term has
one row of that subject and number, `from_crn` can be omitted and the call
replaces that row's CRN. When it has more than one, `from_crn` names the row to
change. Omitting it in that case is `invalid_argument` and nothing is written.
A `crn` already stored on another row is refused, and the other row keeps its
CRN. `add_course` is what creates a second row.

### `apply_reorganize`

Required: `plan_id`, `expected_revision`. Destructive. Runs `reorganize_plan` on the
saved courses and writes the result. A chosen CRN is kept when `section(crn:)` in
that term is a course that remains there. It is not replaced with a different
section of the same subject and number. Two rows with different CRNs stay two
rows. `set_section` is the tool that changes a pin. The response is the
`get_plan` object plus `moves` and `unresolved` from `reorganize_plan`.

### `delete_plan`

Required: `plan_id`, `expected_revision`, `confirm`. Refuses with `confirm_required`
unless `confirm` is `true`. Destructive.

```json
{ "deleted": true, "plan_id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF" }
```

## Errors

Tool failures set `isError` to true. `structuredContent` is exactly:

```json
{
  "error": {
    "code": "revision_conflict",
    "message": "The plan changed. expected_revision was 1 and the saved revision is 2."
  }
}
```

`message` is never empty. Codes outside this list are collapsed before the result is
returned.

| `code` | When |
| --- | --- |
| `invalid_argument` | The arguments are the wrong shape or name a term, time, or day this server does not accept. Also the code for an underlying error that is not one of the codes below. |
| `not_found` | Unknown course, CRN, plan, or a bundled catalog that is not available. `suggest_schedule` uses this when a course has no sections in that term. |
| `revision_conflict` | `expected_revision` is not the saved revision. The message names both numbers. |
| `confirm_required` | `delete_plan` was called without `confirm: true`. |
| `read_only` | A write tool was called while `--read-only` is on. The tool stays hidden from `tools/list`. |
| `storage_error` | The plan file exists but cannot be read, or the write could not be locked or replaced. The message includes the path and the reason. The file is left as it was. |
| `unknown_tool` | The name is not a tool this server implements. |
