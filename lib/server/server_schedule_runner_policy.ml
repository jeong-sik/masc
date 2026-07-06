let interval_sec = 15.0

(* Four missed runner cadences means the production caller has failed to
   observe three complete due windows after the last successful tick. The value
   is surfaced in JSON and does not affect scheduling behavior. *)
let stale_after_sec = interval_sec *. 4.0
