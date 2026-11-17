open Agent_core
module O = Objects_under_test

type ownership = Released | Caller_held
type side = Baseline | Candidate

let checkpoint messages : Checkpoint.t =
  { provider_binding = None
  ; version = Checkpoint.checkpoint_version
  ; session_id = "owned-tool-input-gc"
  ; agent_name = "objects-agent"
  ; model = "objects-model"
  ; system_prompt = Some "be brief"
  ; messages
  ; usage = Types.empty_usage
  ; turn_count = List.length messages
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Types.Off
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Context.create_sync ()
  ; pending_input = None
  ; mcp_sessions = []
  ; working_context = None
  }

let require = function Ok value -> value | Error e -> failwith (Error.to_string e)
let check condition detail = if not condition then failwith detail
let cycles count = for _ = 1 to count do Gc.full_major () done
let ownership_name = function Released -> "released" | Caller_held -> "caller_held"
let side_name = function Baseline -> "baseline" | Candidate -> "candidate"

let input_of_block = function
  | Types.ToolUse { input; _ } -> Some input
  | Types.Text _ | Types.Thinking _ | Types.ReasoningDetails _
  | Types.RedactedThinking _ | Types.ToolResult _ | Types.Image _
  | Types.Document _ | Types.Audio _ -> None

let input_of_checkpoint (cp : Checkpoint.t) =
  match List.concat_map (fun (m : Types.message) -> List.filter_map input_of_block m.content) cp.messages with
  | [input] -> input
  | [] | _ :: _ -> failwith "expected exactly one ToolUse input"

type held =
  { memo : O.memo
  ; decoded : Checkpoint.t
  ; head_bytes : string
  ; content : O.digest
  ; input_weak : Yojson.Safe.t Weak.t
  ; message_weak : Types.message Weak.t
  ; caller : Types.message option ref
  ; encoded_bytes : int
  }

let[@inline never] setup rows ownership =
  let input =
    `Assoc ["rows", `List (List.init rows (fun i ->
      `Assoc ["id", `Int i; "tag", `String (Printf.sprintf "row-%d" i);
              "values", `List [`Int i; `Int (i + 1); `Bool (i mod 2 = 0)]]))]
  in
  let message = Types.make_message ~role:Types.Assistant
    [Types.ToolUse { id = "call-owned-gc"; name = "owned_fixture"; input }] in
  let input_weak = Weak.create 1 and message_weak = Weak.create 1 in
  Weak.set input_weak 0 (Some input);
  Weak.set message_weak 0 (Some message);
  let memo = O.create_memo () in
  let plan = require (O.plan_save memo O.Turn_closes (checkpoint [message])) in
  let decoded_input = input_of_checkpoint plan.decoded in
  check (input != decoded_input) "fixture did not create a distinct decoded input";
  check (input = decoded_input) "decoded input value changed";
  { memo; decoded = plan.decoded; head_bytes = plan.head_bytes; content = plan.content;
    input_weak; message_weak;
    caller = ref (match ownership with Released -> None | Caller_held -> Some message);
    encoded_bytes = O.memo_encoded_bytes memo }

let control_json (c : Gc.control) =
  `Assoc ["minor_heap_size", `Int c.minor_heap_size; "major_heap_increment", `Int c.major_heap_increment;
    "space_overhead", `Int c.space_overhead; "max_overhead", `Int c.max_overhead;
    "allocation_policy", `Int c.allocation_policy; "window_size", `Int c.window_size;
    "custom_major_ratio", `Int c.custom_major_ratio; "custom_minor_ratio", `Int c.custom_minor_ratio;
    "custom_minor_max_size", `Int c.custom_minor_max_size]

let stat_json (s : Gc.stat) =
  `Assoc ["live_words", `Int s.live_words; "heap_words", `Int s.heap_words;
    "free_words", `Int s.free_words; "minor_collections", `Int s.minor_collections;
    "major_collections", `Int s.major_collections; "compactions", `Int s.compactions;
    "forced_major_collections", `Int s.forced_major_collections]

let collection_counts (s : Gc.stat) =
  `Assoc ["minor_collections", `Int s.minor_collections;
    "major_collections", `Int s.major_collections;
    "forced_major_collections", `Int s.forced_major_collections]

let allocated () =
  let minor, promoted, major = Gc.counters () in minor +. major -. promoted

let[@inline never] trial side rows ownership =
  let held = setup rows ownership in
  cycles 8;
  let expected_alive = match side, ownership with
    | Baseline, (Released | Caller_held) | Candidate, Caller_held -> true
    | Candidate, Released -> false in
  let input_alive_before = Weak.check held.input_weak 0
  and message_alive_before = Weak.check held.message_weak 0 in
  check (input_alive_before = expected_alive) "unexpected input witness before timed GC";
  check (message_alive_before = expected_alive) "unexpected message witness before timed GC";
  (* [Gc.stat] forces another collection; both calls are outside the timer. *)
  let before = Gc.stat () in
  let timed_before = Gc.quick_stat () in
  let before_alloc = allocated () in
  let before_cpu = Sys.time () in
  let before_wall = Unix.gettimeofday () in
  cycles 24;
  let wall = Unix.gettimeofday () -. before_wall in
  let cpu = Sys.time () -. before_cpu in
  let allocation = (allocated () -. before_alloc) *. float_of_int (Sys.word_size / 8) in
  let timed_after = Gc.quick_stat () in
  let after = Gc.stat () in
  let input_alive_after = Weak.check held.input_weak 0
  and message_alive_after = Weak.check held.message_weak 0 in
  check (input_alive_after = expected_alive) "unexpected input witness after timed GC";
  check (message_alive_after = expected_alive) "unexpected message witness after timed GC";
  check (require (O.content_digest held.memo held.decoded) = held.content) "decoded digest changed";
  let replay = require (O.plan_save held.memo O.Turn_continues held.decoded) in
  check (replay.content = held.content) "replay content changed";
  (* This future read keeps an intended caller root alive throughout the control. *)
  ignore (Sys.opaque_identity !(held.caller));
  let result = `Assoc ["side", `String (side_name side); "rows", `Int rows;
    "ownership", `String (ownership_name ownership); "untimed_full_major_calls", `Int 8;
    "timed_full_major_calls", `Int 24; "gc_process_cpu_seconds", `Float cpu;
    "gc_wall_seconds", `Float wall; "gc_allocated_bytes", `Float allocation;
    "input_alive_before", `Bool input_alive_before; "message_alive_before", `Bool message_alive_before;
    "input_alive_after", `Bool input_alive_after; "message_alive_after", `Bool message_alive_after;
    "encoded_memo_bytes", `Int held.encoded_bytes;
    "first_head_sha256", `String (O.digest_of_bytes held.head_bytes :> string);
    "content_digest", `String (held.content :> string);
    "replay_head_sha256", `String (O.digest_of_bytes replay.head_bytes :> string);
    "timed_before_counts", collection_counts timed_before;
    "timed_after_counts", collection_counts timed_after;
    "before", stat_json before; "after", stat_json after] in
  ignore (Sys.opaque_identity held);
  result

let () =
  let side = match Array.to_list Sys.argv with
    | [_; "baseline"] -> Baseline
    | [_; "candidate"] -> Candidate
    | [] | [_] | _ :: _ -> failwith "expected baseline or candidate argument" in
  let control = control_json (Gc.get ()) in
  let results = List.concat_map (fun rows ->
    List.map (trial side rows) [Released; Caller_held]) [32768; 131072] in
  print_endline (Yojson.Safe.to_string (`Assoc ["ocaml_version", `String Sys.ocaml_version;
    "word_size", `Int Sys.word_size; "gc_control", control; "results", `List results]))
