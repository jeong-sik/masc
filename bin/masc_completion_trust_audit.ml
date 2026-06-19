(** [masc_completion_trust_audit] — RFC-0262 §9 metric over the live transition
    log.

    Reads the task-transition event stream from [{base}/.masc/events/YYYY-MM/DD.jsonl]
    and folds it through {!Completion_trust_audit} to report the two §9 quantities:
    foreign-task completions by a non-Operator/System actor (§9①, must be 0) and
    force-equivalent completions (§9②, the Phase-3 evidence-gate baseline).

    Ownership is reconstructed from the stream, so the files must be fed in
    chronological order — the [YYYY-MM/DD.jsonl] layout is zero-padded, so a plain
    path sort is chronological.

    Depends only on the pure auditor (+ yojson/unix); it does not link the masc
    runtime. *)

let usage =
  {|Usage: masc_completion_trust_audit [OPTIONS]

Options:
  --events-dir DIR   events root (default: $MASC_BASE_PATH/.masc/events;
                     required when MASC_BASE_PATH is unset)
  --month YYYY-MM    restrict the audit to a single month directory
  --json             emit the metric as JSON instead of the text summary
  --strict           exit 1 if any §9① foreign completion is found
                     (default: informational, exit 0 unless IO error)
  -h, --help         print this help

Exit codes:
  0  audit ran (PASS, or violations found without --strict)
  1  --strict and §9① violations found, or invalid argument
|}
;;

let error msg =
  prerr_endline msg;
  exit 1
;;

let default_events_dir () =
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some p when String.trim p <> "" -> Some (Filename.concat (Filename.concat p ".masc") "events")
  | Some _ | None -> None
;;

type config = {
  events_dir : string option;
  month : string option;
  json : bool;
  strict : bool;
}

let rec parse_args cfg = function
  | [] -> cfg
  | ("-h" | "--help") :: _ ->
    print_string usage;
    exit 0
  | "--events-dir" :: dir :: rest -> parse_args { cfg with events_dir = dir } rest
  | "--month" :: m :: rest -> parse_args { cfg with month = Some m } rest
  | "--json" :: rest -> parse_args { cfg with json = true } rest
  | "--strict" :: rest -> parse_args { cfg with strict = true } rest
  | other :: _ -> error (Printf.sprintf "unknown argument: %S\n%s" other usage)
;;

let resolve_events_dir = function
  | Some dir -> dir
  | None ->
    (match default_events_dir () with
     | Some dir -> dir
     | None ->
       error
         "missing --events-dir: set MASC_BASE_PATH or pass --events-dir explicitly")

(* List [YYYY-MM/DD.jsonl] files under [dir], sorted chronologically. A plain
   [compare] sort is chronological because both segments are zero-padded. *)
let list_event_files ?month dir =
  if not (Sys.file_exists dir) || not (Sys.is_directory dir)
  then []
  else (
    let months =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun mo -> Sys.is_directory (Filename.concat dir mo))
      |> List.sort compare
    in
    let months =
      match month with
      | Some m -> List.filter (String.equal m) months
      | None -> months
    in
    List.concat_map
      (fun mo ->
        let mdir = Filename.concat dir mo in
        Sys.readdir mdir
        |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
        |> List.sort compare
        |> List.map (fun f -> Filename.concat mdir f))
      months)
;;

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])
;;

(* A blank line is not an event (dropped). An unparseable line becomes [`Null] so
   the auditor counts it under [events_skipped] rather than silently vanishing. *)
let parse_line line : Yojson.Safe.t option =
  let line = String.trim line in
  if line = ""
  then None
  else (
    match Yojson.Safe.from_string line with
    | json -> Some json
    | exception _ -> Some `Null)
;;

let () =
  let cfg =
    parse_args
      { events_dir = None; month = None; json = false; strict = false }
      (List.tl (Array.to_list Sys.argv))
  in
  let events_dir = resolve_events_dir cfg.events_dir in
  let files = list_event_files ?month:cfg.month events_dir in
  (if files = []
   then
     prerr_endline
       (Printf.sprintf
          "warning: no event files under %s%s"
          events_dir
          (match cfg.month with Some m -> " for month " ^ m | None -> "")));
  let events =
    List.concat_map
      (fun path -> read_lines path |> List.filter_map parse_line)
      files
  in
  let metric = Completion_trust_audit.audit_events events in
  if cfg.json
  then print_endline (Yojson.Safe.to_string (Completion_trust_audit.metric_to_json metric))
  else print_string (Completion_trust_audit.metric_to_summary metric);
  if cfg.strict && metric.Completion_trust_audit.foreign_assignee_completions <> []
  then exit 1
;;
