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

type gate_decode_summary = {
  parsed_gate_count : int;
  legacy_default_count : int;
}

type entries_read_result = {
  entries : tool_call_entry list;
  gate_decode : gate_decode_summary;
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
(* Thinking entries                                                  *)
(* ================================================================ *)

type thinking_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  content : string;
  content_length : int;
  redacted : bool;
}

type trajectory_line =
  | Tool_call of tool_call_entry
  | Thinking of thinking_entry

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
  | "keeper_fs_edit" -> 0.0001
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

let entry_to_json ?(result_max_len = default_result_truncation)
    ?runtime_contract ?action_radius (e : tool_call_entry) : Yojson.Safe.t =
  let runtime_contract_field =
    match runtime_contract with
    | Some value -> [ ("runtime_contract", value) ]
    | None -> []
  in
  let action_radius_field =
    match action_radius with
    | Some value -> [ ("action_radius", value) ]
    | None -> []
  in
  `Assoc
    ([
       ("ts", `Float e.ts);
       ("ts_iso", `String e.ts_iso);
       ("turn", `Int e.turn);
       ("round", `Int e.round);
       ("tool_name", `String e.tool_name);
       ( "args",
         (try Yojson.Safe.from_string e.args_json with
          | Yojson.Json_error _ -> `String e.args_json) );
       ("gate", gate_decision_to_json e.gate_decision);
       ( "result",
         (match e.result with
          | None -> `Null
          | Some r ->
              if result_max_len > 0 then
                `String
                  (String_util.utf8_safe
                     ~max_bytes:(result_max_len + 3)
                     ~suffix:"..."
                     r
                   |> String_util.to_string)
              else `String r) );
       ("duration_ms", `Int e.duration_ms);
       ("error", Json_util.string_opt_to_json e.error);
       ("cost_usd", `Float e.cost_usd);
     ]
    @ runtime_contract_field @ action_radius_field)

let default_thinking_truncation = 2000

let thinking_entry_to_json ?(content_max_len = default_thinking_truncation) (e : thinking_entry) : Yojson.Safe.t =
  let content =
    if content_max_len > 0 then
      String_util.utf8_safe ~max_bytes:(content_max_len + 3) ~suffix:"..."
        e.content
      |> String_util.to_string
    else e.content
  in
  `Assoc [
    ("type", `String "thinking");
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("turn", `Int e.turn);
    ("content", `String content);
    ("content_length", `Int e.content_length);
    ("redacted", `Bool e.redacted);
  ]

let trajectory_line_to_json ?(result_max_len = default_result_truncation)
    ?(content_max_len = default_thinking_truncation) = function
  | Tool_call e -> entry_to_json ~result_max_len e
  | Thinking e -> thinking_entry_to_json ~content_max_len e

let trajectory_to_json (t : trajectory) : Yojson.Safe.t =
  `Assoc [
    ("scenario_id", Json_util.string_opt_to_json t.scenario_id);
    ("keeper_name", `String t.keeper_name);
    ("trace_id", `String t.trace_id);
    ("generation", `Int t.generation);
    ("started_at", `Float t.started_at);
    ("ended_at", `Float t.ended_at);
    ("total_cost_usd", `Float t.total_cost_usd);
    ("total_turns", `Int t.total_turns);
    ("total_tool_calls", `Int t.total_tool_calls);
    ("outcome", outcome_to_json t.outcome);
    ("task_id", Json_util.string_opt_to_json t.task_id);
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

let append_entry ?runtime_contract ?action_radius ~(masc_root : string)
    ~(keeper_name : string) ~(trace_id : string) (entry : tool_call_entry) :
    unit =
  let dir = trajectories_dir masc_root keeper_name in
  ensure_dir dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let json = entry_to_json ?runtime_contract ?action_radius entry in
  let line = Yojson.Safe.to_string json ^ "\n" in
  Fs_compat.append_file path line

(** Append a thinking block entry to the JSONL trajectory file. *)
let append_thinking ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (entry : thinking_entry) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  ensure_dir dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let json = thinking_entry_to_json entry in
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
    ("task_id", Json_util.string_opt_to_json traj.task_id);
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

(** Clear task binding (e.g., after masc_transition action=done). *)
let clear_task_id (acc : accumulator) : unit =
  acc.task_id <- None

let increment_turn (acc : accumulator) : unit =
  acc.turn <- acc.turn + 1

let record_entry ?runtime_contract ?action_radius ?on_persist_error
    (acc : accumulator) (entry : tool_call_entry) : unit =
  acc.entries <- entry :: acc.entries;
  acc.total_cost <- acc.total_cost +. entry.cost_usd;
  acc.total_calls <- acc.total_calls + 1;
  (* Persist immediately for crash recovery *)
  (try
     append_entry ?runtime_contract ?action_radius ~masc_root:acc.masc_root
       ~keeper_name:acc.keeper_name ~trace_id:acc.trace_id entry
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Keeper.error "Failed to persist entry for %s: %s" acc.trace_id
         (Printexc.to_string exn);
       (match on_persist_error with
        | None -> ()
        | Some report ->
            try report exn
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | report_exn ->
                Log.Keeper.warn
                  "Failed to report trajectory persist gap for %s: %s"
                  acc.trace_id
                  (Printexc.to_string report_exn)))

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

(** Detect whether the current candidate call would make a consecutive streak of
    calls to [tool_name] reach or exceed [threshold]. The count includes the
    candidate call being checked, so rejection can occur before executing the
    threshold-th call.
    If [args_json] is provided, only consecutive calls with the same tool name
    and the same raw [args_json] string are counted; this is string equality,
    not semantic JSON equality. *)
let detect_entropy ?(threshold = 3) ?args_json (acc : accumulator) (tool_name : string) : (string * int) option =
  let recent =
    acc.entries
    |> List.to_seq
    |> Seq.take_while (fun e ->
         e.tool_name = tool_name &&
         match args_json with
         | Some args -> e.args_json = args
         | None -> true)
    |> List.of_seq
  in
  let count = List.length recent + 1 in  (* +1 for the upcoming call *)
  if count >= threshold then Some (tool_name, count)
  else None

(** Count tool calls in current turn. *)
let calls_in_current_turn (acc : accumulator) : int =
  List_util.count_if (fun (e : tool_call_entry) -> e.turn = acc.turn) acc.entries

(* ================================================================ *)
(* Tool stats aggregation                                          *)
(* ================================================================ *)

type tool_stat = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  total_cost_usd : float;
  last_used_at : string;
}

type hourly_bucket = {
  hour : string;
  call_count : int;
  error_count : int;
}

(** Compute p95 from a sorted int array. *)
let p95_of_sorted (durations : int array) : int =
  let n = Array.length durations in
  if n = 0 then 0
  else
    let idx = min (n - 1) (int_of_float (Float.round (float_of_int n *. 0.95))) in
    durations.(idx)

let aggregate_tool_stats (entries : tool_call_entry list) : tool_stat list =
  let tbl : (string, int list * int * int * float * float * string) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter (fun (e : tool_call_entry) ->
    let is_failure = Option.is_some e.error || (match e.gate_decision with Reject _ -> true | Pass -> false) in
    match Hashtbl.find_opt tbl e.tool_name with
    | None ->
      let succ = if is_failure then 0 else 1 in
      let fail = if is_failure then 1 else 0 in
      Hashtbl.replace tbl e.tool_name
        ([e.duration_ms], succ, fail, e.cost_usd, e.ts, e.ts_iso)
    | Some (durations, succ, fail, cost, max_ts, max_iso) ->
      let succ' = if is_failure then succ else succ + 1 in
      let fail' = if is_failure then fail + 1 else fail in
      let (ts', iso') = if e.ts > max_ts then (e.ts, e.ts_iso) else (max_ts, max_iso) in
      Hashtbl.replace tbl e.tool_name
        (e.duration_ms :: durations, succ', fail', cost +. e.cost_usd, ts', iso')
  ) entries;
  let stats = Hashtbl.fold (fun name (durations, succ, fail, cost, _max_ts, last_iso) acc ->
    let count = succ + fail in
    let total_dur = List.fold_left (+) 0 durations in
    let avg = if count > 0 then total_dur / count else 0 in
    let sorted = Array.of_list durations in
    Array.sort compare sorted;
    let max_d = if Array.length sorted > 0 then sorted.(Array.length sorted - 1) else 0 in
    { name;
      call_count = count;
      success_count = succ;
      failure_count = fail;
      avg_duration_ms = avg;
      p95_duration_ms = p95_of_sorted sorted;
      max_duration_ms = max_d;
      total_cost_usd = cost;
      last_used_at = last_iso;
    } :: acc
  ) tbl [] in
  List.sort (fun (a : tool_stat) (b : tool_stat) -> compare b.call_count a.call_count) stats

(** Truncate a Unix timestamp to the start of its UTC hour. *)
let hour_start_iso (ts : float) : string =
  let t = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:00:00Z"
    (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour

let hourly_timeline (entries : tool_call_entry list) : hourly_bucket list =
  let tbl : (string, int * int) Hashtbl.t = Hashtbl.create 24 in
  List.iter (fun (e : tool_call_entry) ->
    let hour = hour_start_iso e.ts in
    let is_err = Option.is_some e.error in
    match Hashtbl.find_opt tbl hour with
    | None -> Hashtbl.replace tbl hour (1, if is_err then 1 else 0)
    | Some (c, errs) -> Hashtbl.replace tbl hour (c + 1, errs + (if is_err then 1 else 0))
  ) entries;
  let buckets = Hashtbl.fold (fun hour (call_count, error_count) acc ->
    { hour; call_count; error_count } :: acc
  ) tbl [] in
  List.sort (fun a b -> String.compare a.hour b.hour) buckets

let tool_stat_to_json (s : tool_stat) : Yojson.Safe.t =
  `Assoc [
    ("name", `String s.name);
    ("call_count", `Int s.call_count);
    ("success_count", `Int s.success_count);
    ("failure_count", `Int s.failure_count);
    ("avg_duration_ms", `Int s.avg_duration_ms);
    ("p95_duration_ms", `Int s.p95_duration_ms);
    ("max_duration_ms", `Int s.max_duration_ms);
    ("total_cost_usd", `Float s.total_cost_usd);
    ("last_used_at", `String s.last_used_at);
  ]

let hourly_bucket_to_json (b : hourly_bucket) : Yojson.Safe.t =
  `Assoc [
    ("hour", `String b.hour);
    ("call_count", `Int b.call_count);
    ("error_count", `Int b.error_count);
  ]

let gate_decision_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "status" fields with
      | Some (`String status) -> (
          match String.lowercase_ascii status with
          | "pass" | "passed" -> (Pass, true)
          | "reject" | "rejected" | "gated" ->
              let reason =
                match List.assoc_opt "reason" fields with
                | Some (`String value) when String.trim value <> "" -> value
                | _ -> "persisted gate rejection"
              in
              (Reject reason, true)
          | _ -> (Pass, false))
      | _ -> (Pass, false))
  | _ -> (Pass, false)

let tool_call_entry_of_json (json : Yojson.Safe.t) :
    (tool_call_entry * bool) option =
  try
    let open Yojson.Safe.Util in
    match member "type" json with
    | `String "trajectory_summary" -> None
    | `String "thinking" -> None
    | _ ->
        let gate_decision, parsed_gate =
          gate_decision_of_json (member "gate" json)
        in
        Some
          ( {
              ts = json |> member "ts" |> to_float;
              ts_iso = json |> member "ts_iso" |> to_string;
              turn = json |> member "turn" |> to_int;
              round = json |> member "round" |> to_int;
              tool_name = json |> member "tool_name" |> to_string;
              args_json = json |> member "args" |> Yojson.Safe.to_string;
              gate_decision;
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
            },
            parsed_gate )
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

(** Read all .jsonl trace files for a keeper. Filter entries with ts >= since.
    Scans the keeper's trajectory directory for all trace files. *)
let read_entries_since_result ~(masc_root : string) ~(keeper_name : string)
    ~(since : float) : entries_read_result =
  let dir = trajectories_dir masc_root keeper_name in
  if not (Sys.file_exists dir) then
    { entries = []; gate_decode = { parsed_gate_count = 0; legacy_default_count = 0 } }
  else
    let files = Sys.readdir dir in
    let all_entries = ref [] in
    let parsed_gate_count = ref 0 in
    let legacy_default_count = ref 0 in
    Array.iter (fun fname ->
      if Filename.check_suffix fname ".jsonl" then begin
        let path = Filename.concat dir fname in
        (try
           let content = Fs_compat.load_file path in
           String.split_on_char '\n' content
           |> List.iter (fun line ->
             if String.trim line <> "" then
               try
                 let json = Yojson.Safe.from_string line in
                 (match tool_call_entry_of_json json with
                  | Some (entry, parsed_gate) when entry.ts >= since ->
                      if parsed_gate then incr parsed_gate_count
                      else incr legacy_default_count;
                      all_entries := entry :: !all_entries
                  | _ -> ())
               with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ())
         with Sys_error _ -> ())
      end
    ) files;
    {
      entries =
        List.sort
          (fun (a : tool_call_entry) (b : tool_call_entry) -> compare a.ts b.ts)
          !all_entries;
      gate_decode =
        {
          parsed_gate_count = !parsed_gate_count;
          legacy_default_count = !legacy_default_count;
        };
    }

let read_entries_since ~(masc_root : string) ~(keeper_name : string)
    ~(since : float) : tool_call_entry list =
  (read_entries_since_result ~masc_root ~keeper_name ~since).entries

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
          match tool_call_entry_of_json json with
          | Some (entry, _parsed_gate) -> Some entry
          | None -> None
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)

(** Read all trajectory lines including thinking entries. *)
let read_all_lines ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    : trajectory_line list =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then []
  else
    let content = Fs_compat.load_file path in
    String.split_on_char '\n' content
    |> List.filter (fun line -> String.trim line <> "")
    |> List.filter_map (fun line ->
        try
          let json = Yojson.Safe.from_string line in
          let open Yojson.Safe.Util in
          match json |> member "type" with
          | `String "trajectory_summary" -> None
          | `String "thinking" ->
              Some (Thinking {
                ts = json |> member "ts" |> to_float;
                ts_iso = json |> member "ts_iso" |> to_string;
                turn = json |> member "turn" |> to_int;
                content = json |> member "content" |> to_string;
                content_length = json |> member "content_length" |> to_int;
                redacted = (match json |> member "redacted" with `Bool b -> b | _ -> false);
              })
          | _ ->
              (match tool_call_entry_of_json json with
               | Some (entry, _parsed_gate) -> Some (Tool_call entry)
               | None -> None)
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
