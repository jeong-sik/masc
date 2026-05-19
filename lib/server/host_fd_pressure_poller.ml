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

let state_file_path () =
  match Sys.getenv_opt "MASC_HOST_FD_PRESSURE_STATE_FILE" with
  | Some s when s <> "" -> s
  | _ -> "/tmp/masc-host-pressure.state"
;;

let poll_interval_sec () =
  Env_config_core.get_float
    ~default:1.0
    "MASC_HOST_FD_PRESSURE_POLL_INTERVAL_SEC"
  |> Float.max 0.5
  |> Float.min 60.0
;;

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
     | _ -> None)
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
    let open Yojson.Safe.Util in
    (try
       let level_str = json |> member "level" |> to_string in
       let level =
         match String.uppercase_ascii level_str with
         | "WARN" -> Some Keeper_fd_pressure.External_warn
         | "CRIT" -> Some Keeper_fd_pressure.External_crit
         | _ -> None
       in
       let ts_str =
         match json |> member "ts" with
         | `String s -> s
         | _ -> ""
       in
       let kinds =
         match json |> member "kinds" with
         | `String s -> s
         | _ -> "?"
       in
       let summary =
         match json |> member "summary" with
         | `String s -> s
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
     | _ -> None)
  | exception _ -> None
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
  if now -. last >= 3600.0 && Atomic.compare_and_set last_warn_log_at last now
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

let start ~sw ~clock =
  Eio.Fiber.fork ~sw (fun () ->
    let path = state_file_path () in
    let interval = poll_interval_sec () in
    Log.Server.info
      "host_fd_pressure_poller: started path=%s interval=%.1fs"
      path
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
