(** MASC Resilience - Single Source of Truth for Failure Handling *)

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

(** Historical Keeper-name convention helper. *)
module Zombie = struct
  (** Check if agent name matches keeper pattern: "keeper-*-agent" (case-insensitive) *)
  let is_keeper_name (name : string) =
    let normalized = String.lowercase_ascii (String.trim name) in
    let prefix = "keeper-" in
    let suffix = "-agent" in
    let nlen = String.length normalized in
    let plen = String.length prefix in
    let slen = String.length suffix in
    nlen > plen + slen
    && String.starts_with normalized ~prefix
    && String.sub normalized (nlen - slen) slen = suffix

end
