(** Tool_autoresearch — MCP tool schemas for the Autoresearch loop.

    Inspired by Karpathy's autoresearch pattern: autonomous experiment cycles
    that generate hypotheses, measure metrics, and keep/discard changes via git.

    Provides 4 MCP tools:
    - masc_autoresearch_start  — Start an autoresearch loop with goal + metric_fn
    - masc_autoresearch_status — Get current loop state (cycle, baseline, history)
    - masc_autoresearch_stop   — Stop a running loop
    - masc_autoresearch_inject — Inject a hypothesis into a running loop

    @since 2.80.0 *)

open Tool_args

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_autoresearch_start";
    description = "Start an autonomous experiment loop (inspired by Karpathy's autoresearch). \
Each cycle: measure baseline → apply change → measure again → keep if improved, discard if not. \
Changes are tracked via git commits. Results are logged to JSONL. \
Requires: goal (what to optimize), metric_fn (shell command that outputs a float on the last line).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "What to optimize (e.g. 'Reduce inference latency')");
        ]);
        ("metric_fn", `Assoc [
          ("type", `String "string");
          ("description", `String "Shell command that outputs a single float on its last line \
(e.g. 'python eval.py --metric accuracy'). Higher is better.");
        ]);
        ("workdir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for git operations and metric_fn \
(default: MASC base path)");
        ]);
        ("max_cycles", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of experiment cycles (default: 100)");
        ]);
        ("cycle_timeout_s", `Assoc [
          ("type", `String "number");
          ("description", `String "Timeout per cycle in seconds (default: 300 = 5min)");
        ]);
        ("baseline", `Assoc [
          ("type", `String "number");
          ("description", `String "Initial baseline score. If omitted, measured by running metric_fn once.");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "metric_fn"]);
    ];
  };

  {
    name = "masc_autoresearch_status";
    description = "Get the current status of an autoresearch loop. \
Returns: loop_id, cycle count, baseline, best score, keep/discard counts, recent history.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest if omitted)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_autoresearch_stop";
    description = "Stop a running autoresearch loop. \
The loop will finish its current cycle and save final state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, stops latest)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for stopping (for logging)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_autoresearch_inject";
    description = "Inject a specific hypothesis into a running autoresearch loop. \
The next cycle will test this hypothesis instead of generating one via LLM. \
Useful for directing the research based on human insight.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("loop_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Loop ID (optional, uses latest)");
        ]);
        ("hypothesis", `Assoc [
          ("type", `String "string");
          ("description", `String "The hypothesis to test in the next cycle");
        ]);
      ]);
      ("required", `List [`String "hypothesis"]);
    ];
  };
]

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type result = bool * string

type context = {
  base_path : string;
}

(* ================================================================ *)
(* Loop Registry                                                    *)
(* ================================================================ *)

(** Global registry of autoresearch loops. *)
let active_loops : (string, Autoresearch.loop_state) Hashtbl.t =
  Hashtbl.create 4

let latest_loop_id : string option ref = ref None

(** Pending hypothesis injections. *)
let pending_hypotheses : (string, string) Hashtbl.t =
  Hashtbl.create 4

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_start ctx args =
  let goal = get_string args "goal" "" in
  let metric_fn = get_string args "metric_fn" "" in
  let workdir = get_string args "workdir" ctx.base_path in
  let max_cycles = get_int args "max_cycles" 100 in
  let cycle_timeout_s = get_float args "cycle_timeout_s" 300.0 in
  if goal = "" then
    `Assoc [("error", `String "goal is required")]
  else if metric_fn = "" then
    `Assoc [("error", `String "metric_fn is required")]
  else begin
    (* Measure initial baseline if not provided *)
    let baseline = match get_float_opt args "baseline" with
      | Some b -> Ok b
      | None ->
        match Autoresearch.measure_metric ~workdir ~timeout_s:cycle_timeout_s metric_fn with
        | Ok (v, _ms) -> Ok v
        | Error e -> Error e
    in
    match baseline with
    | Error e ->
      `Assoc [("error", `String (Printf.sprintf "Failed to measure baseline: %s" e))]
    | Ok baseline_val ->
      let state = Autoresearch.create_state
        ~goal ~metric_fn ~cycle_timeout_s ~max_cycles ~workdir () in
      state.baseline <- baseline_val;
      state.best_score <- baseline_val;
      Autoresearch.save_state ~base_path:ctx.base_path state;
      Hashtbl.replace active_loops state.loop_id state;
      latest_loop_id := Some state.loop_id;
      `Assoc [
        ("loop_id", `String state.loop_id);
        ("status", `String "running");
        ("goal", `String goal);
        ("metric_fn", `String metric_fn);
        ("baseline", `Float baseline_val);
        ("max_cycles", `Int max_cycles);
        ("cycle_timeout_s", `Float cycle_timeout_s);
        ("workdir", `String workdir);
      ]
  end

let resolve_loop_id args =
  match get_string_opt args "loop_id" with
  | Some id -> Some id
  | None -> !latest_loop_id

let handle_status _ctx args =
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    match Hashtbl.find_opt active_loops id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state -> Autoresearch.summary state

let handle_stop ctx args =
  let reason = get_string args "reason" "manual stop" in
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    match Hashtbl.find_opt active_loops id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
      state.status <- Autoresearch.Stopped;
      state.updated_at <- Time_compat.now ();
      Autoresearch.save_state ~base_path:ctx.base_path state;
      `Assoc [
        ("loop_id", `String id);
        ("status", `String "stopped");
        ("reason", `String reason);
        ("final_cycle", `Int state.current_cycle);
        ("best_score", `Float state.best_score);
        ("best_cycle", `Int state.best_cycle);
        ("total_keeps", `Int state.total_keeps);
        ("total_discards", `Int state.total_discards);
      ]

let handle_inject _ctx args =
  let hypothesis = get_string args "hypothesis" "" in
  if hypothesis = "" then
    `Assoc [("error", `String "hypothesis is required")]
  else
    match resolve_loop_id args with
    | None -> `Assoc [("error", `String "No autoresearch loop running")]
    | Some id ->
      match Hashtbl.find_opt active_loops id with
      | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
      | Some state ->
        if state.status <> Autoresearch.Running then
          `Assoc [("error", `String "Loop is not running")]
        else begin
          Hashtbl.replace pending_hypotheses id hypothesis;
          `Assoc [
            ("loop_id", `String id);
            ("status", `String "hypothesis_queued");
            ("hypothesis", `String hypothesis);
            ("will_test_at_cycle", `Int (state.current_cycle + 1));
          ]
        end

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(** Wrap a Yojson.Safe.t result into (success, json_string).
    Returns (false, ...) if the JSON contains an "error" key. *)
let wrap_result json =
  let s = Yojson.Safe.to_string json in
  let is_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  (not is_error, s)

(** Dispatch an autoresearch tool call (standard MCP pattern). *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_autoresearch_start" -> Some (wrap_result (handle_start ctx args))
  | "masc_autoresearch_status" -> Some (wrap_result (handle_status ctx args))
  | "masc_autoresearch_stop" -> Some (wrap_result (handle_stop ctx args))
  | "masc_autoresearch_inject" -> Some (wrap_result (handle_inject ctx args))
  | _ -> None
