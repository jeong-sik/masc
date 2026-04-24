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
let buffer_cap = 64

let ensure_dir path =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    try Sys.mkdir dir 0o755 with
    | Sys_error msg when String_util.contains_substring msg "exists" -> ()
    | Sys_error msg ->
      Log.warn ~ctx:"heuristic_metrics" "cannot mkdir %s: %s" dir msg

let do_flush () =
  match !store_path_ref with
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
    end

let init ~base_path =
  Stdlib.Mutex.protect mu (fun () ->
    match !store_path_ref with
    | Some _ -> ()  (* idempotent *)
    | None ->
      let masc_dir = Coord_utils.masc_dir_from_base_path ~base_path in
      let path = Filename.concat masc_dir "heuristic_metrics.jsonl" in
      store_path_ref := Some path)

let record (e : event) =
  Stdlib.Mutex.protect mu (fun () ->
    let json = event_to_json e in
    Queue.add json buffer;
    if Queue.length buffer >= buffer_cap then
      do_flush ())

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
          Eio.traceln "[HeuristicMetrics] recent read_file_safe failed: %s" msg;
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
  let unique_tuples : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let json_string_field name json =
    match Yojson.Safe.Util.member name json with
    | `String value -> Some value
    | _ -> None
  in
  let json_float_field name json =
    match Yojson.Safe.Util.member name json with
    | `Float value -> Some value
    | `Int value -> Some (Float.of_int value)
    | _ -> None
  in
  let json_bool_field name json =
    match Yojson.Safe.Util.member name json with
    | `Bool value -> Some value
    | _ -> None
  in
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
           let tuple_key =
             Printf.sprintf "%s\000%s\000%.12g\000%.12g\000%b"
               module_name
               site
               (Option.value ~default:Float.nan
                  (json_float_field "raw_value" json))
               (Option.value ~default:Float.nan
                  (json_float_field "threshold" json))
               triggered
           in
           Hashtbl.replace unique_tuples tuple_key ()
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
  {
    total_events = List.length events;
    sites;
    unique_decision_tuples = Hashtbl.length unique_tuples;
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
      ("unique_decision_tuples", `Int report.unique_decision_tuples);
      ("sites", `List (List.map coverage_site_to_json report.sites));
    ]
