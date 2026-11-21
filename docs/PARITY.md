# Platform parity

Behavior both apps share. Logic lives in `TermOrganizeKit`; each platform draws it in its own style.

## Waitlist display

- Banner `waitCapacity`, `waitCount`, `waitAvailable` map to `CourseSection.waitlistCapacity`, `waitlistCount`, `waitlistRemaining`. Data saved without them decodes as 0.
- `waitlistCapacity > 0`: show `Waitlist <count>/<capacity>` beside seats in the section row and detail. With capacity 0 nothing new is shown.
- `waitlistCount > 0` and seats free: the section is not open (`CourseSection.isOpen`). It shows as Waitlist in orange, is left out of "N of M open" and the Open Seats filter, and watchlist seat alerts do not fire.
- No seats and a waitlist: status stays Full, with the waitlist label.

| Surface | iOS | Mac |
| --- | --- | --- |
| Status color and label | `SeatsBadge`, `Theme.seatColor(for:)` | `Theme.seatColor(for:)`, `courseSeatsSpoken` |
| Waitlist size | `CourseSectionCard`, `SeatsBadge` detailed | existing Waitlist column |
