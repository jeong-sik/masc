(** Autoresearch — Autonomous experiment loop inspired by Karpathy's autoresearch.

    Each cycle:
    1. LLM generates hypothesis + code change
    2. git commit (tentative)
    3. Run metric_fn (shell command, bounded by cycle_timeout_s)
    4. Compare score vs baseline
    5. Improved → keep commit, Not improved → git reset
    6. Record result in JSONL
    7. Update baseline (if improved), loop

    Storage: .masc/autoresearch/{loop_id}/results.jsonl

    @since 2.80.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type decision = Keep | Discard

type cycle_record = {
  cycle : int;
  hypothesis : string;
  score_before : float;
  score_after : float;
  delta : float;
  decision : decision;
  commit_hash : string option;
  elapsed_ms : int;
  model_used : string;
  timestamp : float;
}

type status = Running | Completed | Stopped | Error

type loop_state = {
  loop_id : string;
  goal : string;
  metric_fn : string;
  mutable status : status;
  mutable error_message : string option;
  mutable current_cycle : int;
  mutable baseline : float;
  mutable best_score : float;
  mutable best_cycle : int;
  mutable history : cycle_record list;  (** Most recent first *)
  mutable total_keeps : int;
  mutable total_discards : int;
  start_time : float;
  mutable updated_at : float;
  cycle_timeout_s : float;
  max_cycles : int;
  workdir : string;
}

(* ================================================================ *)
(* ID Generation                                                    *)
(* ================================================================ *)

let generate_loop_id () =
  let rnd = Mirage_crypto_rng.generate 4 in
  let hex = String.concat "" (
    List.init (String.length rnd) (fun i ->
      Printf.sprintf "%02x" (Char.code (String.get rnd i))
    )
  ) in
  "ar-" ^ hex

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let decision_to_string = function Keep -> "keep" | Discard -> "discard"

let decision_of_string = function
  | "keep" -> Keep
  | "discard" -> Discard
  | s -> invalid_arg (Printf.sprintf "Unknown decision: %s" s)

let status_to_string = function
  | Running -> "running"
  | Completed -> "completed"
  | Stopped -> "stopped"
  | Error -> "error"

let status_of_string = function
  | "running" -> Some Running
  | "completed" -> Some Completed
  | "stopped" -> Some Stopped
  | "error" -> Some Error
  | _ -> None

let cycle_to_yojson (r : cycle_record) : Yojson.Safe.t =
  `Assoc [
    ("cycle", `Int r.cycle);
    ("hypothesis", `String r.hypothesis);
    ("score_before", `Float r.score_before);
    ("score_after", `Float r.score_after);
    ("delta", `Float r.delta);
    ("decision", `String (decision_to_string r.decision));
    ("commit_hash", match r.commit_hash with
      | Some h -> `String h | None -> `Null);
    ("elapsed_ms", `Int r.elapsed_ms);
    ("model_used", `String r.model_used);
    ("timestamp", `Float r.timestamp);
  ]

let cycle_of_yojson (json : Yojson.Safe.t) : cycle_record =
  let open Yojson.Safe.Util in
  {
    cycle = json |> member "cycle" |> to_int;
    hypothesis = json |> member "hypothesis" |> to_string;
    score_before = json |> member "score_before" |> to_float;
    score_after = json |> member "score_after" |> to_float;
    delta = json |> member "delta" |> to_float;
    decision = json |> member "decision" |> to_string |> decision_of_string;
    commit_hash = json |> member "commit_hash" |> to_string_option;
    elapsed_ms = json |> member "elapsed_ms" |> to_int;
    model_used = json |> member "model_used" |> to_string;
    timestamp = json |> member "timestamp" |> to_float;
  }

let state_to_yojson (s : loop_state) : Yojson.Safe.t =
  `Assoc [
    ("loop_id", `String s.loop_id);
    ("goal", `String s.goal);
    ("metric_fn", `String s.metric_fn);
    ("status", `String (status_to_string s.status));
    ("current_cycle", `Int s.current_cycle);
    ("baseline", `Float s.baseline);
    ("best_score", `Float s.best_score);
    ("best_cycle", `Int s.best_cycle);
    ("total_keeps", `Int s.total_keeps);
    ("total_discards", `Int s.total_discards);
    ("max_cycles", `Int s.max_cycles);
    ("cycle_timeout_s", `Float s.cycle_timeout_s);
    ("workdir", `String s.workdir);
    ("elapsed_s", `Float (Time_compat.now () -. s.start_time));
    ("history_count", `Int (List.length s.history));
    ("error", match s.error_message with
      | Some e -> `String e | None -> `Null);
  ]

(* ================================================================ *)
(* Storage                                                          *)
(* ================================================================ *)

(** Results directory for a loop: .masc/autoresearch/{loop_id}/ *)
let results_dir ~base_path loop_id =
  Filename.concat base_path
    (Filename.concat ".masc"
       (Filename.concat "autoresearch" loop_id))

let results_file ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "results.jsonl"

let state_file ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "state.json"

let ensure_dir path =
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      (try Sys.mkdir dir 0o755 with Sys_error _ -> ())
    end
  in
  mkdir_p path

let append_cycle ~base_path loop_id record =
  let dir = results_dir ~base_path loop_id in
  ensure_dir dir;
  let path = results_file ~base_path loop_id in
  let line = Yojson.Safe.to_string (cycle_to_yojson record) ^ "\n" in
  let oc = open_out_gen [Open_append; Open_creat; Open_text] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc line
  )

let save_state ~base_path state =
  let dir = results_dir ~base_path state.loop_id in
  ensure_dir dir;
  let path = state_file ~base_path state.loop_id in
  let json = Yojson.Safe.pretty_to_string (state_to_yojson state) in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc json
  )

(* ================================================================ *)
(* Metric Measurement                                               *)
(* ================================================================ *)

(** Run metric_fn shell command and parse the last float from stdout.
    Returns Error if command fails or output is not a valid float. *)
let measure_metric ~workdir ~timeout_s metric_fn =
  let timeout_flag = Printf.sprintf "timeout %.0f" timeout_s in
  let cmd = Printf.sprintf "cd %s && %s %s 2>/dev/null | tail -1"
    (Filename.quote workdir) timeout_flag (Filename.quote metric_fn) in
  let start = Time_compat.now () in
  let ic = Unix.open_process_in cmd in
  let output = Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try input_line ic with End_of_file -> ""
  ) in
  let elapsed_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match float_of_string_opt (String.trim output) with
  | Some v -> Ok (v, elapsed_ms)
  | None -> Error (Printf.sprintf "metric_fn output not a float: %S" output)

(* ================================================================ *)
(* Git Operations                                                   *)
(* ================================================================ *)

(** Get current HEAD commit hash (short). *)
let git_head_short ~workdir =
  let cmd = Printf.sprintf "cd %s && git rev-parse --short HEAD 2>/dev/null"
    (Filename.quote workdir) in
  let ic = Unix.open_process_in cmd in
  Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try Some (String.trim (input_line ic)) with End_of_file -> None
  )

(** Commit all changes with a message. Returns commit hash or None on failure. *)
let git_commit ~workdir ~message =
  let cmd = Printf.sprintf
    "cd %s && git add -A && git commit --allow-empty -m %s 2>/dev/null && git rev-parse --short HEAD"
    (Filename.quote workdir) (Filename.quote message) in
  let ic = Unix.open_process_in cmd in
  Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try
      let lines = ref [] in
      (try while true do lines := input_line ic :: !lines done
       with End_of_file -> ());
      match !lines with
      | hash :: _ -> Some (String.trim hash)
      | [] -> None
    with _ -> None
  )

(** Reset to HEAD~1, discarding the last commit. *)
let git_reset_last ~workdir =
  let cmd = Printf.sprintf "cd %s && git reset --hard HEAD~1 2>/dev/null"
    (Filename.quote workdir) in
  ignore (Sys.command cmd)

(* ================================================================ *)
(* Loop State Management                                            *)
(* ================================================================ *)

let create_state ~goal ~metric_fn ~cycle_timeout_s ~max_cycles ~workdir () =
  let now = Time_compat.now () in
  {
    loop_id = generate_loop_id ();
    goal;
    metric_fn;
    status = Running;
    error_message = None;
    current_cycle = 0;
    baseline = 0.0;
    best_score = 0.0;
    best_cycle = 0;
    history = [];
    total_keeps = 0;
    total_discards = 0;
    start_time = now;
    updated_at = now;
    cycle_timeout_s;
    max_cycles;
    workdir;
  }

(** Record one completed experiment cycle. *)
let record_cycle state ~hypothesis ~score_before ~score_after
    ~commit_hash ~elapsed_ms ~model_used =
  let delta = score_after -. score_before in
  let decision = if score_after > score_before then Keep else Discard in
  let record = {
    cycle = state.current_cycle;
    hypothesis;
    score_before;
    score_after;
    delta;
    decision;
    commit_hash;
    elapsed_ms;
    model_used;
    timestamp = Time_compat.now ();
  } in
  state.history <- record :: state.history;
  state.updated_at <- Time_compat.now ();
  (match decision with
   | Keep ->
     state.total_keeps <- state.total_keeps + 1;
     state.baseline <- score_after;
     if score_after > state.best_score then begin
       state.best_score <- score_after;
       state.best_cycle <- state.current_cycle
     end
   | Discard ->
     state.total_discards <- state.total_discards + 1);
  record

(** Check if the loop should continue. *)
let should_continue state =
  state.status = Running && state.current_cycle < state.max_cycles

(** Summary for status reporting. *)
let summary state =
  let recent = List.filteri (fun i _ -> i < 5) state.history in
  let recent_json = `List (List.map cycle_to_yojson recent) in
  let base = state_to_yojson state in
  match base with
  | `Assoc fields ->
    `Assoc (fields @ [("recent_cycles", recent_json)])
  | other -> other
