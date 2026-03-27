(** Dashboard_harness_health — read model for Lab safety harness.

    Aggregates evaluator calibration stats with recent runtime safety signals
    so the Lab surface can explain what the harness is watching. *)

type pre_compact_event = {
  timestamp : float;
  keeper_name : string;
  context_ratio : float;
  message_count : int;
  token_count : int;
  strategies : string list;
  model_family : string;
  trigger : string;
}

type dna_quality_event = {
  timestamp : float;
  keeper_name : string;
  score : float;
  dimensions : Yojson.Safe.t;
}

let max_runtime_events = 12

let pre_compact_events : pre_compact_event list ref = ref []
let dna_quality_events : dna_quality_event list ref = ref []
let runtime_mu = Eio.Mutex.create ()

let trim_recent max_items values =
  if List.length values <= max_items then values
  else List.filteri (fun idx _ -> idx < max_items) values

let push_pre_compact event =
  Eio.Mutex.use_rw ~protect:true runtime_mu (fun () ->
      pre_compact_events := trim_recent max_runtime_events (event :: !pre_compact_events))

let push_dna_quality event =
  Eio.Mutex.use_rw ~protect:true runtime_mu (fun () ->
      dna_quality_events := trim_recent max_runtime_events (event :: !dna_quality_events))

let record_pre_compact ~keeper_name ~context_ratio ~message_count ~token_count
    ~strategies ~model_family ~trigger =
  let event =
    {
      timestamp = Time_compat.now ();
      keeper_name;
      context_ratio;
      message_count;
      token_count;
      strategies;
      model_family;
      trigger;
    }
  in
  push_pre_compact event;
  event

let record_dna_quality ~keeper_name ~score ~dimensions =
  let event =
    {
      timestamp = Time_compat.now ();
      keeper_name;
      score;
      dimensions;
    }
  in
  push_dna_quality event;
  event

let pre_compact_event_json (event : pre_compact_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("context_ratio", `Float event.context_ratio);
      ("message_count", `Int event.message_count);
      ("token_count", `Int event.token_count);
      ("strategies", `List (List.map (fun value -> `String value) event.strategies));
      ("model_family", `String event.model_family);
      ("trigger", `String event.trigger);
    ]

let dna_quality_event_json (event : dna_quality_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("score", `Float event.score);
      ("dimensions", event.dimensions);
    ]

let string_field json key =
  Safe_ops.json_string ~default:"" key json

let recent_verdicts_json ?(limit = 8) ?(since = "") ?(until = "") () =
  let store = Eval_calibration.get_store () in
  let records =
    if since = "" && until = "" then
      Dated_jsonl.read_recent store 500
    else
      let start_date = if since = "" then "2020-01-01" else since in
      let end_date = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range store ~since:start_date ~until:end_date
  in
  let verdicts =
    records
    |> List.filter_map (fun json ->
           if String.equal (string_field json "record_type") "verdict" then
             Some
               (`Assoc
                 [
                   ("timestamp", json |> Yojson.Safe.Util.member "timestamp");
                   ("task_id", `String (string_field json "task_id"));
                   ("task_title", `String (string_field json "task_title"));
                   ("agent_name", `String (string_field json "agent_name"));
                   ("gate", `String (string_field json "gate"));
                   ("verdict", `String (string_field json "verdict"));
                   ( "evaluator_cascade",
                     `String (string_field json "evaluator_cascade") );
                   ( "fallback_reason",
                     match string_field json "fallback_reason" with
                     | "" -> `Null
                     | reason -> `String reason );
                 ])
           else None)
    |> List.sort (fun left right ->
           let ts json =
             Safe_ops.json_float ~default:0.0 "timestamp" json
           in
           Float.compare (ts right) (ts left))
    |> trim_recent limit
  in
  `List verdicts

let recent_pre_compact_json () =
  let events = Eio.Mutex.use_ro runtime_mu (fun () -> !pre_compact_events) in
  `Assoc
    [
      ( "description",
        `String
          "Shows recent context compaction attempts before long-running keeper turns are condensed." );
      ("recent_events", `List (List.map pre_compact_event_json events));
      ("total_recent", `Int (List.length events));
    ]

let recent_dna_quality_json () =
  let events = Eio.Mutex.use_ro runtime_mu (fun () -> !dna_quality_events) in
  `Assoc
    [
      ( "description",
        `String
          "Shows recent continuity DNA quality checks before keeper mitosis or handoff-style spawn flows continue." );
      ("recent_events", `List (List.map dna_quality_event_json events));
      ("total_recent", `Int (List.length events));
    ]

let json ?since ?until () =
  let calibration = Eval_calibration.calibration_stats ?since ?until () in
  `Assoc
    [
      ("generated_at", `Float (Time_compat.now ()));
      ( "scope_note",
        `String
          "Autoresearch tracks the generator loop itself. The safety harness tracks supporting evaluator and long-running continuity rails, so these signals are related but not a direct keep/discard judge for each autoresearch cycle." );
      ("calibration", calibration);
      ("recent_verdicts", recent_verdicts_json ?since ?until ());
      ("pre_compact", recent_pre_compact_json ());
      ("dna_quality", recent_dna_quality_json ());
    ]
