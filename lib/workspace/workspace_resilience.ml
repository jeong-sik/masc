(** Workspace time parsing and observation thresholds. *)

(** Default inactivity warning threshold in seconds (2 minutes) *)
let default_warning_threshold = 120.0

(** Timestamp utilities for resilience checks *)
module Time = struct
  (** Get current time as Unix float *)
  let now () = Time_compat.now ()

  (** Parse ISO 8601 UTC timestamp to Unix epoch.
      Delegates to canonical implementation in Types_core. *)
  let parse_iso8601_opt s =
    match Types_core.parse_iso8601_opt s with
    | Some _ as result -> result
    | None ->
        Log.Misc.error "parse_iso8601_opt failed for: %S" s;
        None

end
