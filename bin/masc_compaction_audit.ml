(** [masc_compaction_audit] — CLI for inspecting the compaction audit JSONL.

    Reads events from [{base}/data/harness-compact/] (plus legacy
    [harness-pre-compact/] fallback) via {!Masc_mcp.Keeper_compact_audit},
    pairs Start/Complete rows by [compaction_id], and prints a human-
    readable summary. Supports date range / keeper filter / orphan-only
    view, plus manual retention prune.

    Invoked as [sb compaction list ...] once wired into the [sb] shim. *)

let usage = {|Usage: masc_compaction_audit [OPTIONS]

Options:
  --since DATE         ISO-8601 date (YYYY-MM-DD), default: 14 days ago
  --until DATE         ISO-8601 date (YYYY-MM-DD), default: today
  --keeper NAME        filter to a single keeper/agent name
  --orphans-only       show only Orphan_start / Orphan_complete rows
  --prune              run retention sweep (default 14 days) and exit
  --retention-days N   days to retain (used by --prune; default 14,
                       env override: MASC_COMPACTION_AUDIT_RETENTION_DAYS)
  -h, --help           print this help

Exit codes:
  0  listing succeeded (rows may be empty)
  1  invalid argument / IO error
|}

let error msg =
  prerr_endline msg;
  exit 1

let parse_date_arg name s =
  match String.length s with
  | 10 ->
    (match
       int_of_string_opt (String.sub s 0 4),
       int_of_string_opt (String.sub s 5 2),
       int_of_string_opt (String.sub s 8 2)
     with
     | Some year, Some mon, Some day ->
       let tm : Unix.tm = {
         tm_sec = 0; tm_min = 0; tm_hour = 0;
         tm_mday = day; tm_mon = mon - 1; tm_year = year - 1900;
         tm_wday = 0; tm_yday = 0; tm_isdst = false;
       } in
       let (ts, _) = Unix.mktime tm in
       ts
     | _ -> error (Printf.sprintf "invalid %s: %S (expected YYYY-MM-DD)" name s))
  | _ -> error (Printf.sprintf "invalid %s: %S (expected YYYY-MM-DD)" name s)

let base_path () =
  (* sb/main_eio uses Masc_mcp.Env_config.base_path.
     Replicating the env lookup avoids pulling heavy deps into this CLI. *)
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some p when p <> "" -> p
  | _ ->
    let home =
      match Sys.getenv_opt "HOME" with
      | Some h -> h
      | None -> "."
    in
    Filename.concat home "me/.masc"

let retention_from_env default =
  match Sys.getenv_opt "MASC_COMPACTION_AUDIT_RETENTION_DAYS" with
  | Some s ->
    (match int_of_string_opt s with
     | Some n when n >= 1 && n <= 365 -> n
     | _ -> default)
  | None -> default

(* ── Argument parsing ─────────────────────────────────────────── *)

type config = {
  since_ts : float;
  until_ts : float;
  keeper   : string option;
  orphans_only : bool;
  prune    : bool;
  retention_days : int;
}

let now () = Unix.gettimeofday ()

let default_since () = now () -. (86400.0 *. 14.0)
let default_until () = now () +. 86400.0

let rec parse_args argv i cfg =
  if i >= Array.length argv then cfg
  else
    match argv.(i) with
    | "-h" | "--help" -> print_endline usage; exit 0
    | "--since" when i + 1 < Array.length argv ->
      parse_args argv (i + 2) { cfg with since_ts = parse_date_arg "since" argv.(i+1) }
    | "--until" when i + 1 < Array.length argv ->
      parse_args argv (i + 2) { cfg with until_ts = parse_date_arg "until" argv.(i+1) +. 86399.0 }
    | "--keeper" when i + 1 < Array.length argv ->
      parse_args argv (i + 2) { cfg with keeper = Some argv.(i+1) }
    | "--orphans-only" ->
      parse_args argv (i + 1) { cfg with orphans_only = true }
    | "--prune" ->
      parse_args argv (i + 1) { cfg with prune = true }
    | "--retention-days" when i + 1 < Array.length argv ->
      (match int_of_string_opt argv.(i+1) with
       | Some n when n >= 1 && n <= 365 ->
         parse_args argv (i + 2) { cfg with retention_days = n }
       | _ -> error (Printf.sprintf "invalid --retention-days: %s" argv.(i+1)))
    | arg -> error (Printf.sprintf "unknown argument: %S\n\n%s" arg usage)

let initial_cfg () = {
  since_ts = default_since ();
  until_ts = default_until ();
  keeper   = None;
  orphans_only = false;
  prune    = false;
  retention_days = retention_from_env 14;
}

(* ── Formatting ───────────────────────────────────────────────── *)

let format_ts ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

module KCA = Masc_mcp.Keeper_compact_audit

let print_paired ~(pre : KCA.start_record) ~(post : KCA.complete_record) =
  let delta = post.before_tokens - post.after_tokens in
  Printf.printf "[%s] %-18s %-10s %s → %d → %d (Δ%d) phase=%s\n"
    (format_ts pre.ts_unix)
    pre.keeper_name
    (KCA.trigger_to_string pre.trigger)
    pre.compaction_id
    post.before_tokens
    post.after_tokens
    delta
    post.phase_hint

let print_orphan_start (s : KCA.start_record) =
  Printf.printf "[%s] %-18s %-10s %s  ORPHAN_START (compaction did not complete)\n"
    (format_ts s.ts_unix) s.keeper_name
    (KCA.trigger_to_string s.trigger) s.compaction_id

let print_orphan_complete (c : KCA.complete_record) =
  Printf.printf "[%s] %-18s %-10s %s  ORPHAN_COMPLETE (start event missing)\n"
    (format_ts c.ts_unix) c.keeper_name "?" c.compaction_id

(* ── Main ─────────────────────────────────────────────────────── *)

let run_list cfg =
  let base = base_path () in
  Eio_main.run @@ fun _env ->
  match
    KCA.read_events ~base_path:base
      ~since:cfg.since_ts ~until:cfg.until_ts
      ?keeper:cfg.keeper ()
  with
  | Error (KCA.Io_failure m | KCA.Serialize_failure m) ->
    error (Printf.sprintf "read failed: %s" m)
  | Ok rows ->
    let paired = KCA.pair_events rows in
    let filtered =
      if cfg.orphans_only then
        List.filter
          (function KCA.Orphan_start _ | KCA.Orphan_complete _ -> true | _ -> false)
          paired
      else paired
    in
    if filtered = [] then
      print_endline "(no rows in range)"
    else
      List.iter
        (function
          | KCA.Paired { start; complete } -> print_paired ~pre:start ~post:complete
          | KCA.Orphan_start s -> print_orphan_start s
          | KCA.Orphan_complete c -> print_orphan_complete c)
        filtered;
    Printf.printf "\n%d row(s). base=%s retention_days=%d\n"
      (List.length filtered) base cfg.retention_days

let run_prune cfg =
  let base = base_path () in
  Eio_main.run @@ fun _env ->
  let n =
    KCA.prune_older_than ~base_path:base ~retention_days:cfg.retention_days
  in
  Printf.printf "pruned %d file(s) older than %d day(s) from %s\n"
    n cfg.retention_days base

let () =
  let cfg = parse_args Sys.argv 1 (initial_cfg ()) in
  if cfg.prune then run_prune cfg
  else run_list cfg
