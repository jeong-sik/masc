### Fixed

- `masc_dashboard` declares the `compact` argument its handler reads, so a
  call can ask for the four-line count summary; the argument was missing from
  the tool definition and refused before it reached the handler (#51211).

### Removed

- `masc_dashboard` no longer takes `scope`. The value was checked against
  `all | current` and then dropped, so both answered the same text, and the
  tool definition named `current` as the default while the handler used
  `all`. A call that still passes `scope` is refused with the name of the
  argument (#51211).
