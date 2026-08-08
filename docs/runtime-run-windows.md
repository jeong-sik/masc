# Runtime Run Windows

`Runtime_store` exposes deterministic read-side windows for runtime replay.

## Ordering

Runs are ordered by ascending `Runtime.session.updated_at`, then ascending
`session_id`. `Last_n_runs(n)` selects the newest `n` runs by that order and
returns them in chronological order.

## Window Selectors

- `Last_n_runs(n)`: newest `n` valid runs; `n <= 0` selects no runs.
- `Session(session_id)`: one named session, reported as a partial failure if
  missing or corrupted.
- `Rolling_seconds(s)`: uses the newest valid run's `updated_at` as the anchor
  and selects runs where `updated_at >= anchor - s`; `s <= 0` selects no runs.

## Partial Failures

Corrupted or incomplete run directories do not fail the whole query. They are
reported in `run_listing.failures` or `run_window_events.failures`; valid runs
and events continue to load.

## Duplicate Events

`read_window_events` accepts multiple selectors. Overlapping selectors are
deduplicated by stable event id `<session_id>#<event.seq>` before returning
events.

## Retention And Compatibility

The read side only scans files currently present under the runtime session
root. Retention is therefore store-driven: deleted run directories simply do
not appear. Existing `Runtime.event` JSON remains the schema authority; event
decode failures are partial failures for the affected run.
