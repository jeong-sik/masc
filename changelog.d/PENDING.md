### Documentation

- RFC-0106's progress table no longer says the cancellation regex lint is
  still active. #37495 replaced it with an arm-list scanner and #40298 deleted
  that scanner with the other bulk source lints, so main has no check for a
  handler that swallows `Cancelled`; the P3 row says so and points at the
  typed-tree check the draft in #52201 proposes (#PENDING).
