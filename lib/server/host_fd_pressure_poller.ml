(* Host_fd_pressure_poller — see .mli for contract.

   RFC-0137 PR-2. Sunsets when RFC-0097 (sandbox container reuse)
   reaches steady state. See RFC-0137 §9.

   Design choices worth noting:
   - The poller does NOT dedup by (level, ts). The downstream
     [Keeper_fd_pressure.engage_external] uses [cas_monotonic_max]
     on [cooldown_until]; a stale [ts] yields a smaller [until_ts]
     and is rejected by the CAS. So even if this poller reads the
     same line twice, behaviour is correct.
   - Parse failures and missing files are no-ops, not warnings —
     during normal operation the file is *absent* most of the time. *)

type state_file_source =
  | Canonical_env
  | Legacy_env
  | Default

type state_file_resolution =
  { path : string
  ; source : state_file_source
  }

let state_file_source_to_string = function
  | Canonical_env -> Env_config_core.host_fd_pressure_state_file_env_key
  | Legacy_env -> Env_config_core.legacy_host_fd_pressure_state_file_env_key
  | Default -> "default"

let default_state_file_path ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "masc-host-pressure.state"
;;

let resolve_state_file_path ~base_path () =
  match
    ( Env_config_core.host_fd_pressure_state_file_path_opt ()
    , Env_config_core.legacy_host_fd_pressure_state_file_path_opt () )
  with
  | Some path, _ -> { path; source = Canonical_env }
  | None, Some path -> { path; source = Legacy_env }
  | None, None -> { path = default_state_file_path ~base_path; source = Default }
;;

let state_file_env_conflict () =
  match
    ( Env_config_core.host_fd_pressure_state_file_path_opt ()
    , Env_config_core.legacy_host_fd_pressure_state_file_path_opt () )
  with
  | Some canonical, Some legacy when not (String.equal canonical legacy) ->
    Some (canonical, legacy)
  | _ -> None
;;

let poll_interval_sec = Env_config_core.host_fd_pressure_poll_interval_sec

(* iso8601 -> unix epoch seconds. sysmon emits e.g.
   "2026-05-19T22:02:26+0900". We strip the trailing tz offset and
   accept the local time as-is — for our purposes the absolute value
   matters only relative to other [ts] values from the same source. *)
let parse_iso8601_opt s =
  match String.split_on_char 'T' s with
  | [ date; rest ] ->
    let time_part =
      (* split off "+0900" or "-0500" or "Z" *)
      let cut_at_tz s =
        let len = String.length s in
        let rec find i =
          if i >= len
          then s
          else
            match s.[i] with
            | '+' | '-' | 'Z' -> String.sub s 0 i
            | _ -> find (i + 1)
        in
        find 0
      in
      cut_at_tz rest
    in
    (try
       Scanf.sscanf
         (date ^ " " ^ time_part)
         "%d-%d-%d %d:%d:%d"
         (fun y mo d h mi s ->
           let tm =
             { Unix.tm_year = y - 1900
             ; tm_mon = mo - 1
             ; tm_mday = d
             ; tm_hour = h
             ; tm_min = mi
             ; tm_sec = s
             ; tm_wday = 0
             ; tm_yday = 0
             ; tm_isdst = false
             }
           in
           let epoch, _ = Unix.mktime tm in
           Some epoch)
     with
     (* RFC-0145 — narrowed from a wildcard catch-all to the only
        exceptions [Scanf.sscanf] / [Unix.mktime] raise on ill-formed
        ISO8601 input.  [Failure] covers numeric conversion failures
        from [Scanf.sscanf] for malformed external timestamps. *)
     | Scanf.Scan_failure _ | Failure _ | End_of_file | Unix.Unix_error _ -> None)
  | _ -> None
;;

type parsed =
  { level : Keeper_fd_pressure.external_level
  ; ts : float
  ; reason : string
  }

let parse_state_line line =
  match Yojson.Safe.from_string line with
  | json ->
    (try
       let level_str = (match Json_util.assoc_member_opt "level" json with Some (`String s) -> s | _ -> "") in
       let level =
         match String.uppercase_ascii level_str with
         | "WARN" -> Some Keeper_fd_pressure.External_warn
         | "CRIT" -> Some Keeper_fd_pressure.External_crit
         | _ -> None
       in
       let ts_str =
         match json |> Json_util.assoc_member_opt "ts" with
         | Some (`String s) -> s
         | _ -> ""
       in
       let kinds =
         match json |> Json_util.assoc_member_opt "kinds" with
         | Some (`String s) -> s
         | _ -> "?"
       in
       let summary =
         match json |> Json_util.assoc_member_opt "summary" with
         | Some (`String s) -> s
         | _ -> ""
       in
       match level, parse_iso8601_opt ts_str with
       | Some level, Some ts ->
         let reason =
           let r = Printf.sprintf "sysmon kinds=%s %s" kinds summary in
           if String.length r > 200 then String.sub r 0 200 else r
         in
         Some { level; ts; reason }
       | _ -> None
     with
     (* RFC-0145 — narrowed from a wildcard to the only exception the
        Yojson projection helpers raise on wrong-typed JSON. *)
     | Yojson.Safe.Util.Type_error _ -> None)
  (* RFC-0145 — narrowed from a wildcard to the only exception
     [Yojson.Safe.from_string] raises on malformed JSON.  An I/O or
     internal runtime exception bubbles to the caller. *)
  | exception Yojson.Json_error _ -> None
;;

let read_state_file_opt path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        match input_line ic with
        | line -> Some line
        | exception End_of_file -> None)
  with
  | Sys_error _ -> None
;;

let last_warn_log_at = Atomic.make 0.0

(* 1 hour throttle for poller WARN logs: parse failures should not flood.
   Takes a thunk so the message-building work is skipped when throttled. *)
let log_throttled_warn (mk_msg : unit -> string) =
  let now = Time_compat.now () in
  let last = Atomic.get last_warn_log_at in
  if now -. last >= Masc_time_constants.hour && Atomic.compare_and_set last_warn_log_at last now
  then Log.Server.warn "%s" (mk_msg ())
;;

let one_tick path =
  match read_state_file_opt path with
  | None -> ()
  | Some line ->
    (match parse_state_line line with
     | Some p ->
       Keeper_fd_pressure.engage_external
         ~reason:p.reason
         ~level:p.level
         ~ts:p.ts
         ()
     | None ->
       log_throttled_warn (fun () ->
         let truncated =
           if String.length line > 80 then String.sub line 0 80 else line
         in
         Printf.sprintf
           "host_fd_pressure_poller: malformed state line (truncated): %s"
           truncated))
;;

let start ~sw ~clock ~base_path =
  Eio.Fiber.fork ~sw (fun () ->
    let resolution = resolve_state_file_path ~base_path () in
    let path = resolution.path in
    let interval = poll_interval_sec () in
    (match state_file_env_conflict () with
     | Some (canonical, legacy) ->
       Log.Server.warn
         "host_fd_pressure_poller: %s=%s overrides legacy %s=%s; set the sysmon \
          producer to the canonical env to avoid split-brain state files"
         Env_config_core.host_fd_pressure_state_file_env_key
         canonical
         Env_config_core.legacy_host_fd_pressure_state_file_env_key
         legacy
     | None -> ());
    Log.Server.info
      "host_fd_pressure_poller: started path=%s source=%s interval=%.1fs"
      path
      (state_file_source_to_string resolution.source)
      interval;
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try one_tick path with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         log_throttled_warn (fun () ->
           Printf.sprintf
             "host_fd_pressure_poller: tick crashed: %s"
             (Printexc.to_string exn)));
      loop ()
    in
    try loop () with
    | Eio.Cancel.Cancelled _ ->
      Log.Server.info "host_fd_pressure_poller: cancelled, exiting cleanly")
;;
