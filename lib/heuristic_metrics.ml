(** Heuristic_metrics -- RFC-0001 Phase 0.1 instrumentation.
    See {!heuristic_metrics.mli}. *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type provenance =
  | Post_verifier of string
  | Thompson of string
  | Drift_guard of string
  | Anti_rationalization of string
  | Agent_reputation of string
  | Relay of string
  | Alert_scoring of string
  | Pipeline_stage of string
  | Board_classify of string
  | Reversibility of string

type event = {
  module_name : string;
  site : string;
  raw_value : float;
  threshold : float;
  triggered : bool;
  provenance : provenance;
  timestamp : float;
}

type coverage_site = {
  module_name : string;
  site : string;
  count : int;
  triggered_count : int;
}

type coverage_report = {
  total_events : int;
  sites : coverage_site list;
  decision_shape_count : int;
  mixed_outcome_sites : int;
  unique_decision_tuples : int;
}

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let provenance_to_json = function
  | Post_verifier dim ->
    `Assoc [("type", `String "post_verifier"); ("detail", `String dim)]
  | Thompson kind ->
    `Assoc [("type", `String "thompson"); ("detail", `String kind)]
  | Drift_guard kind ->
    `Assoc [("type", `String "drift_guard"); ("detail", `String kind)]
  | Anti_rationalization gate ->
    `Assoc [("type", `String "anti_rationalization"); ("detail", `String gate)]
  | Agent_reputation metric ->
    `Assoc [("type", `String "agent_reputation"); ("detail", `String metric)]
  | Relay site ->
    `Assoc [("type", `String "relay"); ("detail", `String site)]
  | Alert_scoring signal ->
    `Assoc [("type", `String "alert_scoring"); ("detail", `String signal)]
  | Pipeline_stage stage ->
    `Assoc [("type", `String "pipeline_stage"); ("detail", `String stage)]
  | Board_classify kind ->
    `Assoc [("type", `String "board_classify"); ("detail", `String kind)]
  | Reversibility est ->
    `Assoc [("type", `String "reversibility"); ("detail", `String est)]

let event_to_json (e : event) : Yojson.Safe.t =
  `Assoc [
    ("module", `String e.module_name);
    ("site", `String e.site);
    ("raw_value", `Float e.raw_value);
    ("threshold", `Float e.threshold);
    ("triggered", `Bool e.triggered);
    ("provenance", provenance_to_json e.provenance);
    ("timestamp", `Float e.timestamp);
  ]

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> Some s
  | _ -> None

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (float_of_int n)
  | _ -> None

let bool_field name fields =
  match List.assoc_opt name fields with
  | Some (`Bool b) -> Some b
  | _ -> None

let non_empty_or fallback value =
  let trimmed = String.trim value in
  if trimmed = "" then fallback else trimmed

let rule_id_of_fields fields =
  let module_name =
    string_field "module" fields |> Option.value ~default:""
    |> non_empty_or "unknown"
  in
  let site =
    string_field "site" fields |> Option.value ~default:""
    |> non_empty_or "unknown"
  in
  if String.equal module_name "unknown" then site
  else module_name ^ "." ^ site

let dashboard_issue_event_to_json (json : Yojson.Safe.t) : Yojson.Safe.t option =
  match json with
  | `Assoc fields ->
      let rule_id = rule_id_of_fields fields in
      let timestamp = float_field "timestamp" fields |> Option.value ~default:0.0 in
      let triggered = bool_field "triggered" fields |> Option.value ~default:false in
      let id = Printf.sprintf "%s:%.3f" rule_id timestamp in
      Some (`Assoc [
        ("id", `String id);
        ("ts", `Float timestamp);
        ("rule_id", `String rule_id);
        ("action", `String (if triggered then "triggered" else "observed"));
        ("cooldown_remaining_ms", `Int 0);
        ("source", `String "heuristic_metrics");
      ])
  | _ -> None

let dashboard_issue_events events =
  List.filter_map dashboard_issue_event_to_json events

let dashboard_feed_json ~limit events =
  `Assoc [
    ("limit", `Int limit);
    ("count", `Int (List.length events));
    ("events", `List events);
    ("heuristics", `List (dashboard_issue_events events));
  ]

(* ================================================================ *)
(* Storage                                                          *)
(* ================================================================ *)

(** File path for the JSONL output. *)
let store_path_ref : string option ref = ref None

(* Stdlib.Mutex: record is non-yielding (Queue.add + file I/O),
   and callers may run outside Eio context (e.g., tests). *)
let mu = Stdlib.Mutex.create ()

(** In-memory buffer to batch writes.  Flushed periodically or on [flush]. *)
let buffer : Yojson.Safe.t Queue.t = Queue.create ()
let default_buffer_cap () = Env_config_runtime.Heuristic_metrics.buffer_cap
let buffer_cap_ref = ref (default_buffer_cap ())

let buffer_cap () =
  max 1 !buffer_cap_ref

(* #10348: time-based flush so sub-cap emit rates produce visible ledger output.
   Without this, the file stays at 0 bytes for low-rate sites (drift_guard
   handoff, env-gated keeper_alert_signal) until the buffer reaches
   [buffer_cap] or shutdown_hooks runs — neither happens in steady-state
   keeper daemons.  Exposed setter is for tests; production code lets the
   30 s default stand. *)
let flush_interval_sec_ref = ref 30.0
let last_flush_ref = ref 0.0
let uninitialized_record_warned_ref = ref false

let set_flush_interval_for_test sec = flush_interval_sec_ref := sec
let set_buffer_cap_for_test cap = buffer_cap_ref := max 1 cap

(* #10348: tests need to re-[init] against fresh tmp paths.  Production
   code only calls [init] once at boot. *)
let reset_for_test () =
  Stdlib.Mutex.protect mu (fun () ->
    store_path_ref := None;
    uninitialized_record_warned_ref := false;
    buffer_cap_ref := default_buffer_cap ();
    Queue.clear buffer;
    (* Initialize the clock to "now" rather than 0.0 so tests that pin a
       large flush interval can verify batching without the [now -.
       last_flush] term swamping it on the first record. *)
    last_flush_ref := Unix.gettimeofday ())

let ensure_dir path =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    try Sys.mkdir dir 0o755 with
    | Sys_error msg when String_util.contains_substring msg "exists" -> ()
    | Sys_error msg ->
      Log.warn ~ctx:"heuristic_metrics" "cannot mkdir %s: %s" dir msg

let do_flush () =
  (match !store_path_ref with
   | None -> ()
   | Some path ->
     if Queue.is_empty buffer then ()
     else begin
       ensure_dir path;
       match
         try Ok (open_out_gen [Open_append; Open_creat; Open_text] 0o644 path)
         with Sys_error msg ->
           Log.warn ~ctx:"heuristic_metrics" "cannot open %s: %s" path msg;
           Error msg
       with
       | Error _ ->
           Log.warn ~ctx:"heuristic_metrics" "flush skipped: %d records remain buffered"
             (Queue.length buffer)
       | Ok oc ->
           Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
             Queue.iter (fun json ->
               output_string oc (Yojson.Safe.to_string json);
               output_char oc '\n'
             ) buffer);
           Queue.clear buffer
     end);
  (* #10348: bump last_flush even on no-op / failed open so the time-based
     re-evaluation in [record] doesn't hammer this path on every event. *)
  last_flush_ref := Unix.gettimeofday ()

let warn_uninitialized_record_once () =
  if not !uninitialized_record_warned_ref then begin
    uninitialized_record_warned_ref := true;
    Log.warn ~ctx:"heuristic_metrics"
      "record called before init; buffering metric events until init \
       installs a base_path"
  end

(* #9919: the pre-fix emit at [keeper_hooks_oas.post_tool_use_failure]
   produced an exact tuple [(site="post_tool_use_failure", raw=1.0,
   threshold=0.0, triggered=true)] that carried no diagnostic signal
   (51 identical rows observed in 48h of production).  The live
   emitter is now a Prometheus counter; this scrub clears the legacy
   residue so boot-time diagnostics and external readers (dashboards,
   governance judgments) stop getting a false-positive degenerate
   site warning for data that is no longer produced. *)
let is_known_degenerate (json : Yojson.Safe.t) : bool =
  match json with
  | `Assoc fields ->
      let get k = List.assoc_opt k fields in
      (match get "site", get "raw_value", get "threshold", get "triggered" with
       | Some (`String "post_tool_use_failure"),
         Some (`Float 1.0 | `Int 1),
         Some (`Float 0.0 | `Int 0),
         Some (`Bool true) -> true
       | _ -> false)
  | _ -> false

let scrub_legacy_degenerate_rows path =
  if not (Sys.file_exists path) then 0
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        Log.warn ~ctx:"heuristic_metrics"
          "#9919 scrub skipped — read failed: %s" msg;
        0
    | Ok content ->
        let lines =
          String.split_on_char '\n' content
          |> List.filter (fun l -> String.length (String.trim l) > 0)
        in
        let kept, dropped =
          List.partition
            (fun line ->
              match Yojson.Safe.from_string line with
              | json -> not (is_known_degenerate json)
              | exception Yojson.Json_error _ ->
                  (* Keep malformed lines — let the existing
                     diagnostics path log them. *)
                  true)
            lines
        in
        let ndrop = List.length dropped in
        if ndrop = 0 then 0
        else begin
          (* Rewrite the file with the kept rows only.  Use atomic
             rename to avoid tearing the file if the process is
             interrupted during init. *)
          let tmp = path ^ ".9919-scrub.tmp" in
          (try
             let oc =
               open_out_gen [Open_wronly; Open_creat; Open_trunc] 0o644 tmp
             in
             Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
               List.iter (fun line ->
                 output_string oc line;
                 output_char oc '\n') kept);
             Sys.rename tmp path;
             Log.Server.info
               "#9919 scrubbed %d legacy degenerate rows from %s \
                (pattern: post_tool_use_failure raw=1.0 threshold=0.0 \
                triggered=true) — emitter has migrated to Prometheus \
                counter [masc_keeper_tool_use_failure_total]"
               ndrop path;
             ndrop
           with Sys_error msg ->
             Log.warn ~ctx:"heuristic_metrics"
               "#9919 scrub skipped — write failed: %s" msg;
             (try Sys.remove tmp with Sys_error _ -> ());
             0)
        end

let init ~base_path =
  Stdlib.Mutex.protect mu (fun () ->
    match !store_path_ref with
    | Some _ -> ()  (* idempotent *)
    | None ->
      let masc_dir = Coord_utils.masc_dir_from_base_path ~base_path in
      let path = Filename.concat masc_dir "heuristic_metrics.jsonl" in
      let _ = scrub_legacy_degenerate_rows path in
      store_path_ref := Some path;
      if not (Queue.is_empty buffer) then do_flush ())

let record (e : event) =
  Stdlib.Mutex.protect mu (fun () ->
    if !store_path_ref = None then warn_uninitialized_record_once ();
    let json = event_to_json e in
    Queue.add json buffer;
    let now = Unix.gettimeofday () in
    let elapsed = now -. !last_flush_ref in
    if Queue.length buffer >= buffer_cap ()
       || elapsed >= !flush_interval_sec_ref
    then do_flush ())

let flush () =
  Stdlib.Mutex.protect mu (fun () ->
    do_flush ())

let recent n =
  match !store_path_ref with
  | None -> []
  | Some path ->
    if not (Sys.file_exists path) then []
    else
      match Safe_ops.read_file_safe path with
      | Error msg ->
          Log.warn ~ctx:"heuristic_metrics" "recent_entries read failed: %s" msg;
          []
      | Ok content ->
        let lines =
          String.split_on_char '\n' content
          |> List.filter (fun l -> String.length (String.trim l) > 0)
        in
        let total = List.length lines in
        let to_skip = max 0 (total - n) in
        let rec drop k = function
          | [] -> []
          | _ :: rest when k > 0 -> drop (k - 1) rest
          | xs -> xs
        in
        drop to_skip lines
        |> List.filter_map (fun line ->
          try Some (Yojson.Safe.from_string line)
          with Yojson.Json_error msg ->
            Log.warn ~ctx:"heuristic_metrics" "dropping malformed line: %s" msg;
            None)

let coverage_report_of_events events =
  let site_counts : ((string * string), (int * int) ref) Hashtbl.t =
    Hashtbl.create 16
  in
  let decision_shapes : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let json_string_field name json = Json_util.get_string json name in
  let json_float_field name json = Json_util.get_float json name in
  let json_bool_field name json = Json_util.get_bool json name in
  List.iter
    (fun json ->
       match json_string_field "module" json, json_string_field "site" json with
       | Some module_name, Some site ->
           let triggered =
             Option.value ~default:false (json_bool_field "triggered" json)
           in
           let key = (module_name, site) in
           let slot =
             match Hashtbl.find_opt site_counts key with
             | Some slot -> slot
             | None ->
                 let slot = ref (0, 0) in
                 Hashtbl.add site_counts key slot;
                 slot
           in
           let count, triggered_count = !slot in
           slot :=
             (count + 1, triggered_count + if triggered then 1 else 0);
           let shape_key =
             Printf.sprintf "%s\000%s\000%.12g\000%b"
               module_name
               site
               (Option.value ~default:Float.nan
                  (json_float_field "threshold" json))
               triggered
           in
           Hashtbl.replace decision_shapes shape_key ()
       | _ -> ())
    events;
  let sites =
    site_counts
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.map (fun ((module_name, site), counts) ->
           let count, triggered_count = !counts in
           { module_name; site; count; triggered_count })
    |> List.sort (fun a b ->
           let c = String.compare a.module_name b.module_name in
           if c <> 0 then c else String.compare a.site b.site)
  in
  let mixed_outcome_sites =
    List.fold_left
      (fun acc site ->
         if site.triggered_count > 0 && site.triggered_count < site.count then
           acc + 1
         else acc)
      0 sites
  in
  let decision_shape_count = Hashtbl.length decision_shapes in
  {
    total_events = List.length events;
    sites;
    decision_shape_count;
    mixed_outcome_sites;
    unique_decision_tuples = decision_shape_count;
  }

let recent_coverage n =
  recent n |> coverage_report_of_events

let coverage_site_to_json site =
  `Assoc
    [
      ("module", `String site.module_name);
      ("site", `String site.site);
      ("count", `Int site.count);
      ("triggered_count", `Int site.triggered_count);
    ]

let coverage_report_to_json report =
  `Assoc
    [
      ("total_events", `Int report.total_events);
      ("decision_shape_count", `Int report.decision_shape_count);
      ("mixed_outcome_sites", `Int report.mixed_outcome_sites);
      ("unique_decision_tuples", `Int report.unique_decision_tuples);
      ("sites", `List (List.map coverage_site_to_json report.sites));
    ]
