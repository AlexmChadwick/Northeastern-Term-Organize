# Term Organize MCP server

Unofficial and not affiliated with Northeastern University.

`term-organize-mcp` speaks [MCP](https://modelcontextprotocol.io) over stdin and stdout
(JSON-RPC 2.0, protocol `2025-06-18`, `Content-Length` framing). It reads only the
Fall 2026 (`202710`) and Spring 2027 (`202730`) catalogs bundled with the app. It does
not open a network connection and it does not log in. Instructor email addresses are
included only when the domain is exactly `northeastern.edu` or `neu.edu`.

The same tool names and JSON shapes are the contract for the Mac, Windows, and Linux
servers. A tool result has `content` (one text block of JSON), `structuredContent`
(the same object), and `isError`. Failures use `structuredContent.error` and
`structuredContent.message`.

Build and client snippets are in the README section [Local MCP server](../README.md#local-mcp-server).

## Catalog location

The server loads `term-202710.catalog` and `term-202730.catalog` from
`NEUClassSearch/Resources/Catalog`, walking up from the current directory, the
executable, and the app bundle. `TERM_ORGANIZE_CATALOG_DIR` overrides that directory.
Any other term code is rejected with `unknown_term`.

## Saved plans

Plans are not stored in SwiftData. The Mac app writes one JSON file, `UserData.json`,
through `UserDataStore`. Each schedule is a `SchedulePlan`: a name, one `termCode`,
the courses, the chosen CRNs, and timestamps. `UserDataStore` loads that file with
`UserDataFile.read` and writes it with `UserDataFile.write`.

On a sandboxed Mac the file is:

```
~/Library/Containers/com.alexchadwick.neuclasssearch/Data/Library/Application Support/UserData.json
```

The shipping entitlements (`NEUClassSearchMac/NEUClassSearchMac.entitlements` and
`NEUClassSearchMac-Local.entitlements`) turn on the app sandbox. They do not include
`com.apple.security.application-groups`. The iOS app and the widgets do share
`group.com.alexchadwick.neuclasssearch`, and that container holds the widget snapshot
only (`WidgetSchedule.json`), not the user's plans.

The MCP process is a normal command-line tool. Claude Desktop and Cursor launch it
outside the app sandbox. An unsandboxed process running as the same user can read and
write the sandboxed app's container. `PlanFileLocation.resolve` uses the container
path when that Application Support directory exists, and otherwise
`AppPaths.userDataURL` (the process Application Support directory, which is what an
unsandboxed app would use). `TERM_ORGANIZE_USER_DATA` overrides the path. Tests set
that variable and never touch a real plans file.

This does not weaken the app sandbox. The entitlements files are unchanged, the tool
is not signed with the app's entitlements, and plans are not copied into the widget
app group. Putting `UserData.json` in that group would expose the whole plans file to
every process that already has the widget group, which the Mac app does not have
today. Embedding the binary inside `Term Organize.app` and giving it the app sandbox
would also fail to share the app's container: a helper launched by Claude or Cursor
is not an XPC service of the app, so a sandbox entitlement would give it a different
container unless an app group were added. The unsandboxed helper, pointed at the
file the app already uses, is the route that leaves the sandbox as it is.

Writes take an exclusive lock (`UserData.json.lock`), copy the previous file to
`UserData.json.bak` (one rolling backup), write a temp file in the same directory,
and `rename` it over `UserData.json`.

The app watches `UserData.json` with a file source and reloads it when the bytes
change, including while the window is already active. Becoming active reloads too.
A reload waits if the app still has an edit that has not been written. That flush
does not replace the file blindly. It compares the file with the last load, using
each plan's revision and a SHA-256 of the bytes (a new modification time counts
only when the bytes changed too). Plans edited on different sides are combined.
When both sides edited the same plan, the file's version stays and the app's
version is saved beside it as "<plan> (edited in app)". An MCP write is not dropped.

### How an MCP plan maps onto schedules

The GUI stores one term per `SchedulePlan`. An MCP plan can span both bundled terms.
Those schedules share an optional `folderID`. The plan id is that UUID. A schedule
the app created with no `folderID` shows up as its own one-term plan, and the plan
id is that schedule's id. The app still lists each term as its own schedule. Both
`folderID` and `revision` are optional, so a `UserData.json` written by an older
build still decodes. A missing revision counts as `0`.

Every write except `create_plan` requires `expected_revision`. The saved revision is
the highest `revision` among the plan's schedules. If it does not match, the tool
returns `revision_conflict` and does not write. A successful write sets every
schedule in the plan to `expected_revision + 1`. The app's own save paths bump
`revision` the same way.

A course is accepted when it exists in either bundled catalog, so a course that is
not taught in the target term can still be saved (that is what reorganize moves).
A CRN, when one is sent, must exist in the requested term and must belong to that
course. Unknown courses and CRNs are rejected and nothing is written.

## Read-only mode

`--read-only`, or `TERM_ORGANIZE_MCP_READONLY=1`, omits every tool whose
`readOnlyHint` is false. `list_plans` and `get_plan` stay. Calling a hidden write
tool returns `read_only`.

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

Only catalogs that actually loaded are listed. `202730` is listed before `202710`
when both loaded.

### `search_courses`

| Field | Required | Notes |
| --- | --- | --- |
| `term` | yes | `202710` or `202730` |
| `query` | no | Same search text the app uses. Empty lists courses in code order. |
| `subject` | no | Compared case-insensitively. |
| `number` | no | Compared case-insensitively. |
| `attribute` | no | Section attribute code, uppercased for the match. |
| `limit` | no | Default 25, maximum 100. |

```json
{
  "term": "202730",
  "courses": [
    {
      "subject": "CS",
      "number": "3000",
      "title": "Algorithms and Data",
      "credits": { "min": 4, "max": 4 },
      "attributes": ["NUpath Natural and Designed World"]
    }
  ]
}
```

### `get_course`

Required: `term`, `subject`, `number`.

The course object from `search_courses`, plus `term`, `description`, and `sections`.

```json
{
  "crn": "12345",
  "section": "01",
  "type": "Lecture",
  "meetings": [
    { "days": ["monday", "wednesday"], "start": "09:50", "end": "11:30", "location": "Snell Library 001" }
  ],
  "instructors": [
    { "name": "Lovelace, Ada", "email": "a.lovelace@northeastern.edu" }
  ],
  "seats": { "remaining": 3, "capacity": 40 }
}
```

`email` is omitted when the address is missing or not on `northeastern.edu` or `neu.edu`.
`start` and `end` are 24-hour `HH:MM` and are omitted when the meeting has no time.
`seats` is omitted when the catalog has neither a capacity nor a remaining count.
`days` uses `sunday` through `saturday`.

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

Required: `term`, `courses` (`[{ "subject", "number" }]`). Optional `constraints`:

| Field | Notes |
| --- | --- |
| `no_classes_before` | `HH:MM`, 24-hour. Classes must start at or after this time. |
| `no_classes_after` | `HH:MM`. Classes must end at or before this time. |
| `days_off` | Array of `sunday` through `saturday`. |

Returns up to 8 conflict-free combinations, best score first. A course with no
sections in that term returns `not_offered`.

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

Does not save. Required: `terms`, each `{ "term", "courses": [{ "subject", "number" }] }`.

Same move as the app's whole-plan reorganize (`DegreePlanReordering`): a course with
no sections in its term is moved to a later bundled term where it is taught, without
breaking prerequisites that are present in the bundled catalogs. The loop stops after
eight moves or when nothing else can move.

```json
{
  "terms": [
    { "term": "202710", "courses": [] },
    { "term": "202730", "courses": [{ "subject": "CS", "number": "3500" }] }
  ],
  "moves": [
    { "subject": "CS", "number": "3500", "from_term": "202710", "to_term": "202730" }
  ],
  "notes": ["Move CS 3500 to Spring 2027"]
}
```

## Plan tools

`updated` is an ISO-8601 timestamp. `revision` is an integer.

### `list_plans`

No arguments. Read-only.

```json
{
  "plans": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
      "name": "Spring",
      "terms": ["202710", "202730"],
      "updated": "2026-10-20T19:00:00Z",
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
  "updated": "2026-10-20T19:00:00Z",
  "terms": [
    {
      "term": "202730",
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

`crn` and `sections` describe the sections chosen on that course. `sections` is empty
when no CRN is chosen. `not_offered` lists courses that have no sections in that
bundled term. `clashes` lists chosen sections whose meetings overlap.

`create_plan`, `rename_plan`, `add_course`, `remove_course`, `move_course`, and
`set_section` return this same object.

### `create_plan`

Required: `name`. Optional: `terms`, each `{ "term", "courses": [{ "subject", "number" }] }`.
With no `terms`, the plan has one schedule on the newest loaded bundled term (`202730`
when that catalog loaded). The new revision is `1`.

### `rename_plan`

Required: `plan_id`, `name`, `expected_revision`.

### `add_course`

Required: `plan_id`, `term`, `subject`, `number`, `expected_revision`. Optional: `crn`.
Creates the term on the plan if it is not there yet.

### `remove_course`

Required: `plan_id`, `term`, `subject`, `number`, `expected_revision`. Destructive.
Also drops CRNs of that course. An emptied extra term is removed. The last remaining
term is kept so the plan id still resolves.

### `move_course`

Required: `plan_id`, `subject`, `number`, `from_term`, `to_term`, `expected_revision`.
The course must already be in `from_term`. A chosen CRN is kept only when that same
CRN is a section of the course in `to_term`.

### `set_section`

Required: `plan_id`, `term`, `subject`, `number`, `crn`, `expected_revision`.
The course must already be in that term. Replaces any CRN previously chosen for it.

### `apply_reorganize`

Required: `plan_id`, `expected_revision`. Destructive. Runs `reorganize_plan` on the
saved courses and writes the result. Chosen CRNs are kept when they still belong to
a course that remains in that term. The response is the `get_plan` object plus
`moves` and `notes` from `reorganize_plan`.

### `delete_plan`

Required: `plan_id`, `expected_revision`, `confirm`. Refuses with `confirm_required`
unless `confirm` is `true`. Destructive.

```json
{ "deleted": true, "plan_id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF" }
```

## Errors

| `error` | When |
| --- | --- |
| `unknown_tool` | The name is not a tool this process is serving. |
| `read_only` | A write tool was called while `--read-only` is on. |
| `catalog_unavailable` | A bundled catalog file could not be loaded. |
| `unknown_term` | The term is not `202710` or `202730`. |
| `unknown_course` | The course is not in the bundled catalogs, or it is not on that plan term. |
| `unknown_crn` | The CRN is not in that term, or it is not a section of that course. |
| `not_offered` | `suggest_schedule` was asked for a course with no sections in that term. |
| `unknown_plan` | `plan_id` does not match a saved plan. |
| `revision_conflict` | `expected_revision` is not the saved revision. `revision` is also returned. |
| `confirm_required` | `delete_plan` was called without `confirm: true`. |
| `bad_plan` | `plan_id` is not a UUID, or `terms` is empty for `reorganize_plan`. |
| `bad_name` | `name` is missing. |
| `bad_revision` | `expected_revision` is missing. |
| `bad_course` | `subject` or `number` is missing. |
| `bad_time` | A constraint time is not `HH:MM`. |
| `bad_day` | A day name is not `sunday` through `saturday`. |
| `missing_courses` | `suggest_schedule` was given an empty `courses` array. |
| `failed` | Any other error. The message is the underlying description. |

`revision_conflict` looks like:

```json
{
  "error": "revision_conflict",
  "message": "The plan changed. expected_revision was 1 and the saved revision is 2.",
  "revision": 2
}
```
