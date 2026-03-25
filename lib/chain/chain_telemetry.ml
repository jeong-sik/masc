(** Chain Telemetry - Event Logging and Observability

    체인 실행 이벤트를 로깅하고 구독 기반 관찰 기능을 제공합니다.

    특징:
    - 비동기 이벤트 발행 (emit)
    - 다중 구독자 지원 (subscribe/unsubscribe)
    - 구조화된 이벤트 타입 (ChainStart, NodeComplete, Error 등)
    - Fiber-safe 구독자 관리 (Eio.Mutex 사용)

    @author Chain Engine
    @since 2026-01
*)


open Chain_category

(** {1 Eio-aware Mutex Guard}

    Delegates to {!Eio_guard.with_mutex} for dual-mode locking. *)
let with_mutex mutex f = Eio_guard.with_mutex mutex f

(** {1 History Persistence} *)

(** History file path - configurable via environment.
    MASC_CHAIN_HISTORY_FILE is canonical; CHAIN_HISTORY_FILE remains a generic fallback. *)
let history_file () =
  match Sys.getenv_opt "MASC_CHAIN_HISTORY_FILE" with
  | Some path when String.trim path <> "" -> path
  | _ -> (
      match Sys.getenv_opt "CHAIN_HISTORY_FILE" with
      | Some path when String.trim path <> "" -> path
      | _ -> "data/chain_history.jsonl")

(** Append a JSON record to history file (thread-safe via OS) *)
let append_history (json : Yojson.Safe.t) =
  try
    Fs_compat.append_jsonl (history_file ()) json
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    (* Log telemetry write errors for debugging - non-critical *)
    Log.Telemetry.error "Write error to %s: %s" (history_file ())
      (Printexc.to_string exn)

(** {1 Event Types} *)

(** Chain start event payload *)
type chain_start_payload = {
  start_chain_id: string;
  start_nodes: int;
  start_timestamp: float;
  start_mermaid_dsl: string option;  (** Mermaid diagram for visualization *)
} [@@deriving yojson]

(** Node start event payload *)
type node_start_payload = {
  node_start_id: string;
  node_start_type: string;
  node_parent: string option;
} [@@deriving yojson]

(** Node complete event payload *)
type node_complete_payload = {
  node_complete_id: string;
  node_duration_ms: int;
  node_tokens: token_usage;
  node_verdict: verdict;
  node_confidence: float;
  node_output_preview: string option;
} [@@deriving yojson]

(** Chain complete event payload *)
type chain_complete_payload = {
  complete_chain_id: string;
  complete_duration_ms: int;
  complete_tokens: token_usage;
  nodes_executed: int;
  nodes_skipped: int;
} [@@deriving yojson]

(** Error event payload *)
type error_payload = {
  error_node_id: string;
  error_message: string;
  error_retries: int;
  error_timestamp: float;
} [@@deriving yojson]

(** All chain events *)
type chain_event =
  | ChainStart of chain_start_payload
  | NodeStart of node_start_payload
  | NodeComplete of node_complete_payload
  | ChainComplete of chain_complete_payload
  | Error of error_payload
[@@deriving yojson]

(** {1 Subscription Management} *)

(** Unique subscription identifier *)
type subscription_id = int

(** Subscription handle *)
type subscription = {
  sub_id: subscription_id;
  mutable active: bool;
}

(** Event handler function type *)
type event_handler = chain_event -> unit

(** Global subscription registry *)
let next_sub_id = ref 0
let subscribers : (subscription_id, event_handler) Hashtbl.t = Hashtbl.create 16
let subscribers_mutex = Eio.Mutex.create ()

(** {1 Running Chains Tracking} *)

(** Running chain info: (chain_id, started_at, progress) *)
type running_chain_info = {
  chain_id: string;
  started_at: float;
  mutable progress: float;  (** 0.0 to 1.0 *)
  mutable _nodes_completed: int;
  total_nodes: int;
}

let running_chains : (string, running_chain_info) Hashtbl.t = Hashtbl.create 16
let running_chains_mutex = Eio.Mutex.create ()

(** Register a chain as running *)
let register_running_chain ~chain_id ~total_nodes =
  with_mutex running_chains_mutex (fun () ->
    let info = {
      chain_id;
      started_at = Unix.gettimeofday ();
      progress = 0.0;
      _nodes_completed = 0;
      total_nodes;
    } in
    Hashtbl.replace running_chains chain_id info
  )

(** Update chain progress *)
let update_chain_progress ~chain_id ~nodes_completed =
  with_mutex running_chains_mutex (fun () ->
    match Hashtbl.find_opt running_chains chain_id with
    | Some info ->
        info._nodes_completed <- nodes_completed;
        info.progress <- if info.total_nodes > 0
          then float_of_int nodes_completed /. float_of_int info.total_nodes
          else 0.0
    | None -> ()
  )

(** Unregister a completed chain *)
let unregister_running_chain ~chain_id =
  with_mutex running_chains_mutex (fun () ->
    Hashtbl.remove running_chains chain_id
  )

(** Get all running chains *)
let get_running_chains () : (string * float * float) list =
  with_mutex running_chains_mutex (fun () ->
    Hashtbl.fold (fun _id info acc ->
      (info.chain_id, info.started_at, info.progress) :: acc
    ) running_chains []
  )

(** Generate next subscription ID *)
let gen_sub_id () =
  let id = !next_sub_id in
  incr next_sub_id;
  id

(** {1 Event Emission} *)

(** Save significant events to history *)
let save_to_history event =
  let now = Unix.gettimeofday () in
  let record = match event with
    | ChainStart p ->
        Some (`Assoc [
          ("event", `String "chain_start");
          ("chain_id", `String p.start_chain_id);
          ("nodes", `Int p.start_nodes);
          ("timestamp", `Float now);
          ("mermaid_dsl", match p.start_mermaid_dsl with Some s -> `String s | None -> `Null);
        ])
    | ChainComplete p ->
        Some (`Assoc [
          ("event", `String "chain_complete");
          ("chain_id", `String p.complete_chain_id);
          ("duration_ms", `Int p.complete_duration_ms);
          ("tokens", token_usage_to_yojson p.complete_tokens);
          ("nodes_executed", `Int p.nodes_executed);
          ("nodes_skipped", `Int p.nodes_skipped);
          ("timestamp", `Float now);
        ])
    | Error p ->
        Some (`Assoc [
          ("event", `String "chain_error");
          ("node_id", `String p.error_node_id);
          ("message", `String p.error_message);
          ("retries", `Int p.error_retries);
          ("timestamp", `Float now);
        ])
    | _ -> None  (* Only persist chain-level events *)
  in
  match record with Some r -> append_history r | None -> ()

(** Emit an event to all subscribers *)
let emit event =
  (* Save to history file (chain_start, chain_complete, chain_error only) *)
  save_to_history event;
  (* Get handlers snapshot under lock *)
  let handlers = with_mutex subscribers_mutex (fun () ->
    Hashtbl.fold (fun _ handler acc -> handler :: acc) subscribers []
  ) in
  (* Call handlers outside of lock to avoid deadlocks *)
  List.iter (fun handler ->
    try handler event
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Chain.warn "chain_telemetry: event handler failed: %s" (Printexc.to_string exn)
  ) handlers

(** {1 Subscription API} *)

(** Subscribe to chain events *)
let subscribe handler =
  with_mutex subscribers_mutex (fun () ->
    let id = gen_sub_id () in
    Hashtbl.add subscribers id handler;
    { sub_id = id; active = true }
  )

(** Unsubscribe from chain events *)
let unsubscribe sub =
  if sub.active then
    with_mutex subscribers_mutex (fun () ->
      Hashtbl.remove subscribers sub.sub_id;
      sub.active <- false
    )

(** Check if subscription is active *)
let is_active sub = sub.active

(** Get number of active subscribers *)
let subscriber_count () =
  with_mutex subscribers_mutex (fun () ->
    Hashtbl.length subscribers
  )

(** {1 Event Constructors} *)

(** Create a ChainStart event *)
let chain_start ~chain_id ~nodes ?mermaid_dsl () =
  ChainStart {
    start_chain_id = chain_id;
    start_nodes = nodes;
    start_timestamp = Unix.gettimeofday ();
    start_mermaid_dsl = mermaid_dsl;
  }

(** Create a NodeStart event *)
let node_start ~node_id ~node_type ?parent () =
  NodeStart {
    node_start_id = node_id;
    node_start_type = node_type;
    node_parent = parent;
  }

(** Create a NodeComplete event *)
let node_complete ~node_id ~duration_ms ~tokens ~verdict ~confidence ?output_preview () =
  NodeComplete {
    node_complete_id = node_id;
    node_duration_ms = duration_ms;
    node_tokens = tokens;
    node_verdict = verdict;
    node_confidence = confidence;
    node_output_preview = output_preview;
  }

(** Create a ChainComplete event *)
let chain_complete ~chain_id ~duration_ms ~tokens ~executed ~skipped =
  ChainComplete {
    complete_chain_id = chain_id;
    complete_duration_ms = duration_ms;
    complete_tokens = tokens;
    nodes_executed = executed;
    nodes_skipped = skipped;
  }

(** Create an Error event *)
let error ~node_id ~message ~retries =
  Error {
    error_node_id = node_id;
    error_message = message;
    error_retries = retries;
    error_timestamp = Unix.gettimeofday ();
  }

(** {1 Event Logging} *)

(** Event log buffer for persistence *)
let event_log : chain_event list ref = ref []
let event_log_mutex = Eio.Mutex.create ()
let max_log_size = ref 10000

(** Logging subscriber that buffers events *)
let logging_handler event =
  with_mutex event_log_mutex (fun () ->
    event_log := event :: !event_log;
    (* Trim if exceeds max size *)
    if List.length !event_log > !max_log_size then
      event_log := List.filteri (fun i _ -> i < !max_log_size) !event_log
  )

(** Initialize logging subscriber *)
let logging_subscription = ref None

let enable_logging ?(max_size=10000) () =
  max_log_size := max_size;
  match !logging_subscription with
  | Some _ -> () (* Already enabled *)
  | None ->
    logging_subscription := Some (subscribe logging_handler)

let disable_logging () =
  match !logging_subscription with
  | None -> ()
  | Some sub ->
    unsubscribe sub;
    logging_subscription := None

(** Get recent events from log *)
let get_recent_events ?(limit=100) () =
  with_mutex event_log_mutex (fun () ->
    let events = List.filteri (fun i _ -> i < limit) !event_log in
    List.rev events  (* Return in chronological order *)
  )

(** Clear event log *)
let clear_log () =
  with_mutex event_log_mutex (fun () ->
    event_log := []
  )

(** {1 Filtering} *)

(** Filter predicate type *)
type event_filter = chain_event -> bool

(** Filter: only chain events *)
let chain_events_only = function
  | ChainStart _ | ChainComplete _ -> true
  | _ -> false

(** Filter: only node events *)
let node_events_only = function
  | NodeStart _ | NodeComplete _ -> true
  | _ -> false

(** Filter: only errors *)
let errors_only = function
  | Error _ -> true
  | _ -> false

(** Filter: events for specific chain *)
let for_chain chain_id = function
  | ChainStart p -> p.start_chain_id = chain_id
  | ChainComplete p -> p.complete_chain_id = chain_id
  | _ -> true  (* Node events don't have chain_id *)

(** Filter: events for specific node *)
let for_node node_id = function
  | NodeStart p -> p.node_start_id = node_id
  | NodeComplete p -> p.node_complete_id = node_id
  | Error p -> p.error_node_id = node_id
  | _ -> false

(** Subscribe with filter *)
let subscribe_filtered ~filter handler =
  subscribe (fun event ->
    if filter event then handler event
  )

(** {1 Serialization} *)

(** Convert event to JSON string *)
let event_to_json_string event =
  Yojson.Safe.to_string (chain_event_to_yojson event)

(** Parse event from JSON string *)
let event_of_json_string str =
  match Yojson.Safe.from_string str with
  | json -> chain_event_of_yojson json
  | exception (Yojson.Json_error msg) -> Result.Error ("Invalid JSON: " ^ msg)

(** {1 Pretty Printing} *)

(** Format event for human-readable output *)
let string_of_event = function
  | ChainStart p ->
    Printf.sprintf "[CHAIN_START] %s (%d nodes) at %.3f"
      p.start_chain_id p.start_nodes p.start_timestamp
  | NodeStart p ->
    Printf.sprintf "[NODE_START] %s (%s)%s"
      p.node_start_id p.node_start_type
      (match p.node_parent with Some p -> " parent:" ^ p | None -> "")
  | NodeComplete p ->
    Printf.sprintf "[NODE_COMPLETE] %s in %dms, %d tokens, %s (%.2f confidence)"
      p.node_complete_id p.node_duration_ms p.node_tokens.total_tokens
      (match p.node_verdict with
       | Pass s -> "PASS:" ^ s
       | Warn s -> "WARN:" ^ s
       | Fail s -> "FAIL:" ^ s
       | Defer s -> "DEFER:" ^ s)
      p.node_confidence
  | ChainComplete p ->
    Printf.sprintf "[CHAIN_COMPLETE] %s in %dms, %d tokens, %d/%d nodes"
      p.complete_chain_id p.complete_duration_ms p.complete_tokens.total_tokens
      p.nodes_executed (p.nodes_executed + p.nodes_skipped)
  | Error p ->
    Printf.sprintf "[ERROR] %s: %s (retries: %d) at %.3f"
      p.error_node_id p.error_message p.error_retries p.error_timestamp

(** {1 Console Logger} *)

(** Create a console logging handler *)
let console_handler ?(prefix="[CHAIN]") event =
  Log.Telemetry.info "%s %s" prefix (string_of_event event)

(** Subscribe console logger *)
let enable_console_logging ?(prefix="[CHAIN]") () =
  subscribe (console_handler ~prefix)
