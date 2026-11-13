### Fixed

- Evaluator verdict rows (`.masc/verdicts/`) are read by one decoder, the
  inverse of the writer, in the calibration statistics, the divergence
  analysis and the dashboard's recent verdict list. A row the current writer
  does not produce (an earlier key name, a gate or verdict outside the current
  vocabulary, a missing key) is in no count or list. It used to be read with
  empty strings and a zero timestamp in place of what was missing. The
  statistics report the number of such rows as `unreadable_record_count` and
  the harness health envelope as `recent_verdicts_unreadable_count` (#42937, #PENDING).
