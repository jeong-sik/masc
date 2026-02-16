(** Tool_experiment - GAME-VIEW social experiment tools.

    Handles: experiment.start
    Enforces precondition: decision.finalize must exist for session.
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room_utils.config;
  agent_name: string;
}

type run = {
  experiment_id: string;
  session_id: string;
  decision_id: string;
  hypothesis: string;
  treatment: string;
  control: string;
  metrics: string list;
  guardrails: string list;
  window_sec: int;
  started_at: float;
  started_by: string;
}

let protocol = "masc.game-view/0.1"

let get_string args key default =
  match args |> member key with
  | `String s -> s
  | _ -> default

let get_string_opt args key =
  match args |> member key with
  | `String s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

let get_int args key default =
  match args |> member key with
  | `Int i -> i
  | _ -> default

let get_string_list args key =
  match args |> member key with
  | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let result_envelope payload =
  `Assoc [
    ("protocol", `String protocol);
    ("type", `String "result");
    ("domain", `String "experiment");
    ("name", `String "experiment.start");
    ("payload", payload);
  ]

let error_envelope ~code ~message ~retryable ~details =
  `Assoc [
    ("protocol", `String protocol);
    ("type", `String "error");
    ("domain", `String "experiment");
    ("name", `String "experiment.start");
    ("payload", `Assoc [
      ("code", `String code);
      ("message", `String message);
      ("retryable", `Bool retryable);
      ("details", details);
    ]);
  ]

let precondition_error ~session_id ~reason =
  error_envelope
    ~code:"PRECONDITION_REQUIRED"
    ~message:"decision.finalize is required before experiment.start"
    ~retryable:false
    ~details:(`Assoc [
      ("session_id", `String session_id);
      ("required_command", `String "decision.finalize");
      ("reason", `String reason);
    ])

let validation_error ~message =
  error_envelope
    ~code:"VALIDATION_ERROR"
    ~message
    ~retryable:false
    ~details:(`Assoc [])

let runs_path config =
  Filename.concat (Room.masc_dir config) "game_view_experiments.json"

let run_to_json r =
  `Assoc [
    ("experiment_id", `String r.experiment_id);
    ("session_id", `String r.session_id);
    ("decision_id", `String r.decision_id);
    ("hypothesis", `String r.hypothesis);
    ("treatment", `String r.treatment);
    ("control", `String r.control);
    ("metrics", `List (List.map (fun s -> `String s) r.metrics));
    ("guardrails", `List (List.map (fun s -> `String s) r.guardrails));
    ("window_sec", `Int r.window_sec);
    ("started_at", `Float r.started_at);
    ("started_by", `String r.started_by);
  ]

let load_runs config =
  let path = runs_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "runs" with
       | `List items -> items
       | _ -> [])

let append_run config run =
  let path = runs_path config in
  let existing = load_runs config in
  Room_utils.write_json config path
    (`Assoc [("runs", `List (run_to_json run :: existing))])

let require_finalized_decision ctx args =
  let session_id = get_string args "session_id" "" in
  if session_id = "" then
    Error (validation_error ~message:"session_id is required")
  else
    let decision_id = get_string_opt args "decision_id" in
    match Game_view_state.finalized_decision_for_session ?decision_id ctx.config ~session_id with
    | Ok d -> Ok (session_id, d)
    | Error reason -> Error (precondition_error ~session_id ~reason)

let handle_experiment_start ctx args =
  match require_finalized_decision ctx args with
  | Error err_json ->
      (false, Yojson.Safe.pretty_to_string err_json)
  | Ok (session_id, decision) ->
      let now = Time_compat.now () in
      let experiment_id =
        Printf.sprintf "exp-%Ld" (Int64.of_float (now *. 1_000_000.0))
      in
      let run = {
        experiment_id;
        session_id;
        decision_id = decision.decision_id;
        hypothesis = get_string args "hypothesis" "";
        treatment = get_string args "treatment" "";
        control = get_string args "control" "";
        metrics = get_string_list args "metrics";
        guardrails = get_string_list args "guardrails";
        window_sec = max 1 (get_int args "window_sec" 3600);
        started_at = now;
        started_by = ctx.agent_name;
      } in
      append_run ctx.config run;
      let payload = `Assoc [
        ("experiment_id", `String run.experiment_id);
        ("status", `String "running");
        ("session_id", `String run.session_id);
        ("decision_ref", `String run.decision_id);
        ("hypothesis", `String run.hypothesis);
        ("metrics", `List (List.map (fun s -> `String s) run.metrics));
        ("guardrails", `List (List.map (fun s -> `String s) run.guardrails));
        ("window_sec", `Int run.window_sec);
        ("started_at", `Float run.started_at);
      ] in
      (true, Yojson.Safe.pretty_to_string (result_envelope payload))

let dispatch ctx ~name ~args : result option =
  match name with
  | "experiment.start" -> Some (handle_experiment_start ctx args)
  | _ -> None
