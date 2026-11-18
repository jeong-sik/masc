/** The two `projection_status` vocabularies of a dashboard schedule row, in
 *  the declaration order of `Schedule_contract_values`. The server writes
 *  them through that table; schedule-projection-status.test.ts checks these
 *  lists against api/fixtures/schedule-projection-statuses.json, and
 *  test_schedule_projection_status_contract checks the fixture against the
 *  OCaml table, so a value added, renamed or removed on the server fails both
 *  until this list follows (#36009). */
export const SCHEDULE_QUEUE_PROJECTION_STATUSES = [
  'matched_pending',
  'retained_terminal_wake',
  'withdrawn_at_cancel',
  'not_found',
  'matched_terminal_completed',
  'matched_terminal_cancelled',
  'terminal_projection_pending',
  'transfer_projection_pending',
  'evidence_invalid',
  'read_error',
  'unrecognized_receipt',
] as const

export type ScheduleQueueProjectionStatus = (typeof SCHEDULE_QUEUE_PROJECTION_STATUSES)[number]

export const SCHEDULE_REACTION_PROJECTION_STATUSES = [
  'conflicting_terminal_evidence',
  'matched_terminal_cancelled',
  'matched_consumed_ack',
  'matched_turn_finished',
  'matched_turn_started',
  'matched_stimulus',
  'not_found',
  'quarantined',
  'read_error',
  'missing_stimulus_id',
  'invalid_stimulus_id',
  'unrecognized_receipt',
] as const

export type ScheduleReactionProjectionStatus =
  (typeof SCHEDULE_REACTION_PROJECTION_STATUSES)[number]
