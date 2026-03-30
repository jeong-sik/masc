(** Trajectory — JSONL-based tool call trajectory logging for Keeper Harness.

    Records every tool call invocation (pre + post) to enable:
    - Deterministic replay of agent behavior
    - Cost accumulation and budget enforcement
    - Entropy detection (repeated tool calls)
    - Behavioral evaluation via eval_harness.ml

    Each keeper session produces a trajectory file at:
      .masc/trajectories/{keeper_name}/{trace_id}.jsonl

    @since 2.73.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type gate_decision =
  | Pass
  | Reject of string  (** reason *)

type tool_call_entry = {
  ts : float;                       (** Unix timestamp *)
  ts_iso : string;                  (** ISO8601 string *)
  turn : int;                       (** Turn number within session *)
  round : int;                      (** Tool round within turn (1-3) *)
  tool_name : string;
  args_json : string;               (** Raw JSON string of arguments *)
  gate_decision : gate_decision;    (** Pre-execution gate result *)
  result : string option;           (** None if gated/pending, Some output *)
  duration_ms : int;                (** Wall-clock execution time *)
  error : string option;            (** Exception message if failed *)
  cost_usd : float;                 (** Estimated cost of this call *)
}

type trajectory_outcome =
  | Completed
  | Failed of string
  | Timeout
  | CostExceeded
  | Gated of string  (** rejected by pre-execution gate *)

type trajectory = {
  scenario_id : string option;      (** None for live runs, Some for eval *)
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_cost_usd : float;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
  task_id : string option;
  (** Claimed task ID for cost attribution.
      Set when keeper claims a task via masc_claim; None if no task claimed.
      Enables per-task cost aggregation from trajectory summaries. *)
}

(* ================================================================ *)
(* Cost estimation                                                  *)
(* ================================================================ *)

(* model_token_pricing and estimate_turn_cost removed (#3029).
   Pricing belongs to OAS cascade, not MASC.
   MASC records cost_usd from OAS responses via emit_cost_event. *)

(** Rough per-call cost estimates for keeper tools.
    Most are local/free; only MODEL-calling tools have cost. *)
let tool_cost_estimate (tool_name : string) : float =
  match tool_name with
  (* MODEL-intensive tools *)
  | "keeper_board_post" -> 0.002
  | "keeper_board_comment" -> 0.001
  | "keeper_bash" -> 0.0001
  | "keeper_github" -> 0.0001
  | "keeper_fs_edit" | "keeper_edit" -> 0.0001
  (* Read-only tools are essentially free *)
  | _ -> 0.0

(* ================================================================ *)
(* JSON serialization                                               *)
(* ================================================================ *)

let gate_decision_to_json = function
  | Pass -> `Assoc [("status", `String "pass")]
  | Reject reason -> `Assoc [("status", `String "reject"); ("reason", `String reason)]

let outcome_to_json = function
  | Completed -> `String "completed"
  | Failed msg -> `Assoc [("status", `String "failed"); ("reason", `String msg)]
  | Timeout -> `String "timeout"
  | CostExceeded -> `String "cost_exceeded"
  | Gated reason -> `Assoc [("status", `String "gated"); ("reason", `String reason)]

let outcome_to_string = function
  | Completed -> "completed"
  | Failed msg -> Printf.sprintf "failed: %s" msg
  | Timeout -> "timeout"
  | CostExceeded -> "cost_exceeded"
  | Gated reason -> Printf.sprintf "gated: %s" reason

(** Default truncation limit for result text in JSONL persistence. *)
let default_result_truncation = 500

let entry_to_json ?(result_max_len = default_result_truncation) (e : tool_call_entry) : Yojson.Safe.t =
  `Assoc [
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("turn", `Int e.turn);
    ("round", `Int e.round);
    ("tool_name", `String e.tool_name);
    ("args", (try Yojson.Safe.from_string e.args_json with Yojson.Json_error _ -> `String e.args_json));
    ("gate", gate_decision_to_json e.gate_decision);
    ("result",
      (match e.result with
       | None -> `Null
       | Some r ->
           if result_max_len > 0 && String.length r > result_max_len then
             `String (String.sub r 0 result_max_len ^ "...")
           else `String r));
    ("duration_ms", `Int e.duration_ms);
    ("error", (match e.error with None -> `Null | Some e -> `String e));
    ("cost_usd", `Float e.cost_usd);
  ]

let trajectory_to_json (t : trajectory) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id",
      (match t.scenario_id with None -> `Null | Some s -> `String s));
    ("keeper_name", `String t.keeper_name);
    ("trace_id", `String t.trace_id);
    ("generation", `Int t.generation);
    ("started_at", `Float t.started_at);
    ("ended_at", `Float t.ended_at);
    ("total_cost_usd", `Float t.total_cost_usd);
    ("total_turns", `Int t.total_turns);
    ("total_tool_calls", `Int t.total_tool_calls);
    ("outcome", outcome_to_json t.outcome);
    ("task_id",
      (match t.task_id with None -> `Null | Some s -> `String s));
    ("entries", `List (List.map entry_to_json t.entries));
  ]

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let trajectories_dir (masc_root : string) (keeper_name : string) : string =
  Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper_name)

let trajectory_path (masc_root : string) (keeper_name : string) (trace_id : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name)
    (Printf.sprintf "%s.jsonl" trace_id)

let ensure_dir path =
  Fs_compat.mkdir_p path

let append_entry ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (entry : tool_call_entry) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  ensure_dir dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let json = entry_to_json entry in
  let line = Yojson.Safe.to_string json ^ "\n" in
  Fs_compat.append_file path line

(** Write a trajectory summary line (appended after session ends). *)
let append_summary ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (traj : trajectory) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  ensure_dir dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let summary = `Assoc [
    ("type", `String "trajectory_summary");
    ("keeper_name", `String traj.keeper_name);
    ("trace_id", `String traj.trace_id);
    ("generation", `Int traj.generation);
    ("total_cost_usd", `Float traj.total_cost_usd);
    ("total_turns", `Int traj.total_turns);
    ("total_tool_calls", `Int traj.total_tool_calls);
    ("outcome", outcome_to_json traj.outcome);
    ("task_id",
      (match traj.task_id with None -> `Null | Some s -> `String s));
    ("started_at", `Float traj.started_at);
    ("ended_at", `Float traj.ended_at);
  ] in
  let line = Yojson.Safe.to_string summary ^ "\n" in
  Fs_compat.append_file path line

(* ================================================================ *)
(* Trajectory accumulator (mutable, per-session)                    *)
(* ================================================================ *)

type accumulator = {
  mutable entries : tool_call_entry list;
  mutable total_cost : float;
  mutable total_calls : int;
  mutable turn : int;
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  masc_root : string;
  mutable task_id : string option;
  (** Claimed task ID for cost attribution.
      Starts as None; set via [set_task_id] when keeper claims a task.
      Propagated to trajectory record on [finalize]. *)
}

let create_accumulator ~masc_root ~keeper_name ~trace_id ~generation : accumulator =
  { entries = [];
    total_cost = 0.0;
    total_calls = 0;
    turn = 0;
    keeper_name;
    trace_id;
    generation;
    started_at = Time_compat.now ();
    masc_root;
    task_id = None;
  }

(** Bind a claimed task to this trajectory for cost attribution. *)
let set_task_id (acc : accumulator) (id : string) : unit =
  acc.task_id <- Some id

(** Clear task binding (e.g., after masc_done). *)
let clear_task_id (acc : accumulator) : unit =
  acc.task_id <- None

let increment_turn (acc : accumulator) : unit =
  acc.turn <- acc.turn + 1

let record_entry (acc : accumulator) (entry : tool_call_entry) : unit =
  acc.entries <- entry :: acc.entries;
  acc.total_cost <- acc.total_cost +. entry.cost_usd;
  acc.total_calls <- acc.total_calls + 1;
  (* Persist immediately for crash recovery *)
  (try append_entry ~masc_root:acc.masc_root ~keeper_name:acc.keeper_name
       ~trace_id:acc.trace_id entry
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Keeper.error "Failed to persist entry for %s: %s" acc.trace_id (Printexc.to_string exn))

let finalize (acc : accumulator) (outcome : trajectory_outcome) : trajectory =
  let traj = {
    scenario_id = None;
    keeper_name = acc.keeper_name;
    trace_id = acc.trace_id;
    generation = acc.generation;
    started_at = acc.started_at;
    ended_at = Time_compat.now ();
    entries = List.rev acc.entries;
    total_cost_usd = acc.total_cost;
    total_turns = acc.turn;
    total_tool_calls = acc.total_calls;
    outcome;
    task_id = acc.task_id;
  } in
  (try append_summary ~masc_root:acc.masc_root ~keeper_name:acc.keeper_name
       ~trace_id:acc.trace_id traj
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Keeper.error "Failed to persist summary for %s: %s" acc.trace_id (Printexc.to_string exn));
  traj

(* ================================================================ *)
(* Entropy detection                                                *)
(* ================================================================ *)

(** Detect repeated tool calls: if the same tool is called N+ times
    consecutively, return Some(tool_name, count). *)
let detect_entropy ?(threshold = 3) (acc : accumulator) (tool_name : string) : (string * int) option =
  let recent =
    acc.entries
    |> List.to_seq
    |> Seq.take_while (fun e -> e.tool_name = tool_name)
    |> List.of_seq
  in
  let count = List.length recent + 1 in  (* +1 for the upcoming call *)
  if count >= threshold then Some (tool_name, count)
  else None

(** Count tool calls in current turn. *)
let calls_in_current_turn (acc : accumulator) : int =
  List.length (List.filter (fun (e : tool_call_entry) -> e.turn = acc.turn) acc.entries)

(* ================================================================ *)
(* Read trajectory from JSONL (for replay/eval)                     *)
(* ================================================================ *)

let read_entries ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    : tool_call_entry list =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then []
  else
    let content = Fs_compat.load_file path in
    String.split_on_char '\n' content
    |> List.filter (fun line -> String.trim line <> "")
    |> List.filter_map (fun line ->
        try
          let json = Yojson.Safe.from_string line in
          (* Skip summary lines *)
          match Yojson.Safe.Util.member "type" json with
          | `String "trajectory_summary" -> None
          | _ ->
              let open Yojson.Safe.Util in
              Some {
                ts = json |> member "ts" |> to_float;
                ts_iso = json |> member "ts_iso" |> to_string;
                turn = json |> member "turn" |> to_int;
                round = json |> member "round" |> to_int;
                tool_name = json |> member "tool_name" |> to_string;
                args_json = json |> member "args" |> Yojson.Safe.to_string;
                gate_decision = Pass;  (* Simplified for replay *)
                result =
                  (match json |> member "result" with
                   | `Null -> None
                   | `String s -> Some s
                   | _ -> None);
                duration_ms = json |> member "duration_ms" |> to_int;
                error =
                  (match json |> member "error" with
                   | `Null -> None
                   | `String s -> Some s
                   | _ -> None);
                cost_usd = json |> member "cost_usd" |> to_float;
              }
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
