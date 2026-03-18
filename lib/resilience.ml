(** MASC Resilience - Single Source of Truth for Failure Handling *)

(** Default zombie threshold in seconds - from Env_config *)
let default_zombie_threshold = Env_config.Zombie.threshold_seconds

(** Default inactivity warning threshold in seconds (2 minutes) *)
let default_warning_threshold = 120.0

(** Timestamp utilities for resilience checks *)
module Time = struct
  (** Get current time as Unix float *)
  let now () = Time_compat.now ()

  (** Parse ISO 8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SSZ") to Unix epoch.

      [Unix.mktime] interprets its argument as local time. To get the
      correct UTC epoch we compute the local-UTC offset and add it.

      [tz_offset = local_epoch - utc_as_local] yields a positive value
      for east-of-UTC zones (e.g. +32400 for KST/UTC+9).
      [local_epoch + tz_offset] then recovers the true UTC epoch. *)
  let parse_iso8601_opt s =
    try
      Scanf.sscanf s "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (fun year mon day hour min sec ->
          let tm = {
            Unix.tm_sec = sec; tm_min = min; tm_hour = hour;
            tm_mday = day; tm_mon = mon - 1; tm_year = year - 1900;
            tm_wday = 0; tm_yday = 0; tm_isdst = false;
          } in
          let local_epoch, _ = Unix.mktime tm in
          let utc_of_local = Unix.gmtime local_epoch in
          let utc_as_local, _ = Unix.mktime utc_of_local in
          let tz_offset = local_epoch -. utc_as_local in
          Some (local_epoch +. tz_offset))
    with Scanf.Scan_failure _ | Failure _ | End_of_file ->
      Log.Misc.error "parse_iso8601_opt failed for: %S" s;
      None

  (** Check if a timestamp is older than threshold *)
  let is_stale ?(threshold=default_zombie_threshold) timestamp_str =
    match parse_iso8601_opt timestamp_str with
    | Some ts -> (now ()) -. ts > threshold
    | None -> true (* Treat invalid timestamps as stale/zombie *)
end

(** Zombie detection logic *)
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
    && String.sub normalized 0 plen = prefix
    && String.sub normalized (nlen - slen) slen = suffix

  (** Check if an agent is a zombie based on last_seen timestamp *)
  let is_zombie ?(threshold=default_zombie_threshold) last_seen_iso =
    Time.is_stale ~threshold last_seen_iso

  (** Check if an agent is a zombie, using keeper threshold for keeper agents *)
  let is_zombie_for_agent ~agent_name last_seen_iso =
    let threshold =
      if is_keeper_name agent_name
      then Env_config.Zombie.keeper_threshold_seconds
      else default_zombie_threshold
    in
    is_zombie ~threshold last_seen_iso
end

(** {1 Zero-Zombie Protocol} *)

module ZeroZombie = struct
  type stats = {
    mutable total_cleanups: int;
    mutable last_cleanup_ts: float;
    mutable last_cleaned_agents: string list;
  }

  let global_stats = {
    total_cleanups = 0;
    last_cleanup_ts = 0.0;
    last_cleaned_agents = [];
  }

  (** Run a cleanup cycle using provided cleanup function.
      Returns list of cleaned agent names. *)
  let cleanup ~cleanup_fn =
    let cleaned = cleanup_fn () in
    if List.length cleaned > 0 then begin
      global_stats.total_cleanups <- global_stats.total_cleanups + 1;
      global_stats.last_cleanup_ts <- Time.now ();
      global_stats.last_cleaned_agents <- cleaned
    end;
    cleaned

  (** Eio-native background loop for automatic cleanup.
      @param interval cleanup interval in seconds (default: 60s)
      @param cleanup_fn function that performs the actual cleanup and returns names *)
  (** Check if error is benign (e.g., not initialized - normal at startup) *)
  let is_benign_error exn =
    let msg = Printexc.to_string exn in
    String.length msg >= 20 && 
    (String.sub msg 0 20 = "Invalid_argument(\"MA" ||  (* MASC not initialized *)
     String.sub msg 0 14 = "Sys_error(\"No ")         (* No such file - transient *)

  let run_loop ?(interval=60.0) ~clock ~cleanup_fn () =
    let is_cancelled exn =
      match exn with
      | Eio.Cancel.Cancelled _ -> true
      | _ -> false
    in
    let rec loop () =
      (try Eio.Time.sleep clock interval
       with exn ->
         if is_cancelled exn then raise exn;
         Log.Misc.error "sleep error: %s" (Printexc.to_string exn));
      (try
         ignore (cleanup ~cleanup_fn)
       with exn ->
         if is_cancelled exn then raise exn;
         (* Silently ignore benign errors like "not initialized" *)
         if not (is_benign_error exn) then
           Log.Misc.error "cleanup error: %s" (Printexc.to_string exn));
      loop ()
    in
    try loop () with exn ->
      if is_cancelled exn then raise exn
      else if not (is_benign_error exn) then
        Log.Misc.error "loop error: %s" (Printexc.to_string exn)
end
