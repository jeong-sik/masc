(** MASC Resilience - Single Source of Truth for Failure Handling *)

(** Default zombie threshold in seconds.
    Reads MASC_ZOMBIE_THRESHOLD_SEC (default 300s = 5 minutes). *)
let default_zombie_threshold = Env_config_runtime.Zombie.threshold_seconds

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
    && String.starts_with normalized ~prefix
    && String.sub normalized (nlen - slen) slen = suffix

  (** Check if an agent is a zombie based on last_seen timestamp *)
  let is_zombie ?(threshold=default_zombie_threshold) last_seen_iso =
    Time.is_stale ~threshold last_seen_iso

  let agent_type_is_keeper agent_type =
    (* STR-OK: boundary parser for the file-backed agent_type keeper stamp. *)
    String.lowercase_ascii (String.trim agent_type) = "keeper"

  (** Check if the file-backed agent record is a real keeper.  Keeper-shaped
      names are not authority here: spoofed worker names must not inherit the
      longer keeper grace. *)
  let is_keeper_record ~agent_type ~(agent_meta : Masc_domain.agent_meta option) =
    agent_type_is_keeper agent_type
    ||
    match agent_meta with
    | Some { keeper_id = Some _; _ } | Some { keeper_name = Some _; _ } -> true
    | _ -> false

  (** Backward-compatible wrapper for callers that only have name/type.  The
      name argument is intentionally ignored for keeper-grace decisions. *)
  let is_keeper ~name:_ ~agent_type =
    agent_type_is_keeper agent_type

  (** Check if an agent is a zombie, using keeper threshold for keeper agents *)
  let is_zombie_for_agent
      ?(keeper_threshold_sec = Env_config_runtime.Zombie.keeper_threshold_seconds)
      ?(agent_threshold_sec = default_zombie_threshold)
      ?(agent_type = "")
      ?agent_meta
      ~agent_name:_
      last_seen_iso =
    let threshold =
      if is_keeper_record ~agent_type ~agent_meta
      then keeper_threshold_sec
      else agent_threshold_sec
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
    if cleaned <> [] then begin
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
    (String.starts_with msg ~prefix:"Invalid_argument(\"MA" ||
     String.starts_with msg ~prefix:"Sys_error(\"No ")

  let run_loop ?(interval=60.0) ~clock ~cleanup_fn () =
    let is_cancelled exn =
      match exn with
      | Eio.Cancel.Cancelled _ -> true
      | _ -> false
    in
    let rec loop () =
      (try Eio.Time.sleep clock interval
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         if is_cancelled exn then raise exn;
         Log.Misc.error "sleep error: %s" (Printexc.to_string exn));
      (try
         ignore (cleanup ~cleanup_fn)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         if is_cancelled exn then raise exn;
         (* Silently ignore benign errors like "not initialized" *)
         if not (is_benign_error exn) then
           Log.Misc.error "cleanup error: %s" (Printexc.to_string exn));
      loop ()
    in
    try loop () with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then raise exn
      else if not (is_benign_error exn) then
        Log.Misc.error "loop error: %s" (Printexc.to_string exn)
end
