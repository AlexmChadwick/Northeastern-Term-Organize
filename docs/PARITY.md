# Platform parity

Behavior both apps share. Logic lives in `TermOrganizeKit`; each platform draws it in its own style.

## Waitlist display

- Banner `waitCapacity`, `waitCount`, `waitAvailable` map to `CourseSection.waitlistCapacity`, `waitlistCount`, `waitlistRemaining`. Data saved without them decodes as 0.
- `waitlistCapacity > 0`: show `Waitlist <count>/<capacity>` beside seats in the section row and detail. With capacity 0 nothing new is shown.
- `waitlistCount > 0` and seats free: the section is not open (`CourseSection.isOpen`). It shows as Waitlist in orange, is left out of "N of M open" and the Open Seats filter, and watchlist seat alerts do not fire.
- No seats and a waitlist: status stays Full, with the waitlist label.
- One helper, `CourseSection.openSeats` (0 when `waitlistCount > 0`, else `seatsRemaining`), is read everywhere openness matters: course aggregates ("N of M open", seat totals, Open seats sort), section status and seat text, generator hide-full and min seats and its seat measures, preference rules (`isFull`, Open seats only, All sections open), schedule "N open" and full warnings, `isFull` (= not `isOpen`), and watch seeding and alerts.
- Status word: seats 0 is Full, seats free behind a queue is Waitlist, else Open. The word Waitlist is never printed twice: where the `Waitlist n/cap` fact is shown it replaces the status word.
- Decision, capacity 0: `waitlistCount > 0` with `waitlistCapacity == 0` is not open and shows `Waitlist n` (no cap). Sections with no seat limit at all (capacity 0, seats 0) keep "No limit listed" and are never full for preference rules.
- Decision, cross-listed sections: seats come from `crossListAvailable` but `waitlistCount` is the section's own and is not aggregated across siblings, so a queue on a sibling is not seen.

| Surface | iOS | Mac |
| --- | --- | --- |
| Status color and label | `SeatsBadge`, `Theme.seatColor(for:)` | `Theme.seatColor(for:)`, `courseSeatsSpoken` |
| Waitlist size | `CourseSectionCard`, `SeatsBadge` detailed | existing Waitlist column |
