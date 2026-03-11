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
  llm_model : string;
  target_file : string;  (** File the LLM reads and modifies, relative to workdir *)
  mutable status : status;
  mutable error_message : string option;
  mutable current_cycle : int;
  mutable baseline : float;
  mutable best_score : float;
  mutable best_cycle : int;
  mutable history : cycle_record list;  (** Most recent first *)
  mutable total_keeps : int;
  mutable total_discards : int;
  mutable insights : string list;  (** Accumulated experiment insights, FIFO max 10 *)
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
    ("llm_model", `String s.llm_model);
    ("target_file", `String s.target_file);
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
    ("insights_count", `Int (List.length s.insights));
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
    (Filename.quote workdir) timeout_flag metric_fn in
  let start = Time_compat.now () in
  let ic = Unix.open_process_in cmd in
  let output = Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try input_line ic with End_of_file -> ""
  ) in
  let elapsed_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match float_of_string_opt (String.trim output) with
  | Some v -> Result.ok (v, elapsed_ms)
  | None -> Result.error (Printf.sprintf "metric_fn output not a float: %S" output)

(** Check if [needle] is a substring of [haystack]. *)
let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then
        found := true
    done;
    !found

(** Run metric_fn with retry on transient errors (timeout, connection).
    Returns Ok (score, total_elapsed_ms) or Error on non-transient failure.
    max_retries=2 means up to 3 total attempts. *)
let measure_metric_with_retry ~workdir ~timeout_s ?(max_retries = 2) metric_fn =
  let is_transient err =
    let lower = String.lowercase_ascii err in
    contains_substring lower "timeout" || contains_substring lower "connection"
  in
  let rec attempt n =
    match measure_metric ~workdir ~timeout_s metric_fn with
    | Ok _ as ok -> ok
    | Error e when n < max_retries && is_transient e ->
      Unix.sleepf 1.0;
      attempt (n + 1)
    | Error _ as err -> err
  in
  attempt 0

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

(** Commit staged/unstaged changes with a message.
    Returns commit hash or None if nothing to commit.
    No --allow-empty: real file changes required. *)
let git_commit ~workdir ~message =
  let cmd = Printf.sprintf
    "cd %s && git add -A && git diff --cached --quiet; \
     if [ $? -ne 0 ]; then git commit -m %s 2>/dev/null && git rev-parse --short HEAD; fi"
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

(** Commit with autoresearch-formatted message. *)
let git_commit_cycle ~workdir ~cycle ~hypothesis ~baseline =
  let message = Printf.sprintf "[autoresearch] cycle %d: %s (baseline=%.4f)"
    cycle hypothesis baseline in
  git_commit ~workdir ~message

(** Tag the current HEAD as the best result so far. *)
let git_tag_best ~workdir ~cycle ~score =
  let tag = Printf.sprintf "ar-best-c%d-%.4f" cycle score in
  let cmd = Printf.sprintf "cd %s && git tag -f %s 2>/dev/null"
    (Filename.quote workdir) (Filename.quote tag) in
  ignore (Sys.command cmd)

(* ================================================================ *)
(* LLM Hypothesis Generation                                        *)
(* ================================================================ *)

(* ================================================================ *)
(* Target File Validation & I/O                                     *)
(* ================================================================ *)

(** Check if path contains traversal components (../ or /.. or bare ..). *)
let has_path_traversal path =
  path = ".."
  || contains_substring path "../"
  || (let len = String.length path in
      len >= 3 && String.sub path (len - 3) 3 = "/..")

(** Validate target_file: must be relative, no path traversal, must exist,
    must not escape workdir via symlink.
    Returns Ok absolute_path or Error reason. *)
let validate_target_file ~workdir target_file =
  if String.length target_file = 0 then
    Result.error "target_file is empty"
  else if String.get target_file 0 = '/' then
    Result.error (Printf.sprintf "target_file must be relative: %s" target_file)
  else if has_path_traversal target_file then
    Result.error (Printf.sprintf "target_file contains '..': %s" target_file)
  else
    let abs = Filename.concat workdir target_file in
    if not (Sys.file_exists abs) then
      Result.error (Printf.sprintf "target_file not found: %s" abs)
    else
      let real_path = Unix.realpath abs in
      let real_workdir = Unix.realpath workdir in
      let prefix_len = String.length real_workdir in
      if String.length real_path >= prefix_len
         && String.sub real_path 0 prefix_len = real_workdir then
        Result.ok real_path
      else
        Result.error (Printf.sprintf
          "target_file escapes workdir via symlink: %s" target_file)

(** Read entire file contents. *)
let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let n = in_channel_length ic in
    let buf = Bytes.create n in
    really_input ic buf 0 n;
    Bytes.to_string buf
  )

(** Apply code change: write new_content to target_file atomically.
    Writes to a temp file in the same directory, then renames.
    Returns Ok original_content (for rollback reference) or Error reason. *)
let apply_code_change ~workdir ~target_file ~new_content =
  match validate_target_file ~workdir target_file with
  | (Result.Error _) as e -> e
  | Result.Ok abs_path ->
    let original = read_file abs_path in
    let dir = Filename.dirname abs_path in
    let tmp_path = Filename.concat dir
      (Printf.sprintf ".autoresearch_tmp_%d" (Unix.getpid ())) in
    (try
      let oc = open_out tmp_path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc new_content
      );
      Unix.rename tmp_path abs_path;
      Result.ok original
    with exn ->
      (try Sys.remove tmp_path with _ -> ());
      Result.error (Printf.sprintf "Failed to write %s: %s"
        target_file (Printexc.to_string exn)))

(* ================================================================ *)
(* LLM Code Change Generation                                       *)
(* ================================================================ *)

(** Build prompt for LLM code change. Exported for testing. *)
let build_code_change_prompt ~goal ~baseline ~history ~insights
    ~file_content ~target_file =
  let recent = List.filteri (fun i _ -> i < 5) history in
  let history_lines = List.map (fun (r : cycle_record) ->
    Printf.sprintf "  Cycle %d: %s -> delta=%.4f (%s)"
      r.cycle r.hypothesis r.delta (decision_to_string r.decision)
  ) recent in
  let insight_lines = List.map (fun s -> "  - " ^ s) insights in
  String.concat "\n" ([
    "You are an autonomous research assistant optimizing code.";
    Printf.sprintf "Goal: %s" goal;
    Printf.sprintf "Current baseline score: %.4f (higher is better)" baseline;
    Printf.sprintf "Target file: %s" target_file;
  ] @ (if history_lines <> [] then
    [""; "Recent experiment history:"] @ history_lines
  else []) @ (if insight_lines <> [] then
    [""; "Accumulated insights:"] @ insight_lines
  else []) @ [
    "";
    "<current_code>";
    file_content;
    "</current_code>";
    "";
    "Modify the code to improve the metric score.";
    "Reply with exactly:";
    "1. A <hypothesis> tag containing a one-line description of your change";
    "2. A <modified_code> tag containing the COMPLETE modified file";
    "";
    "Example format:";
    "<hypothesis>Increase batch size from 32 to 64 for better throughput</hypothesis>";
    "<modified_code>";
    "... complete file content ...";
    "</modified_code>";
  ])

(** Extract text between XML-style tags. *)
let extract_tag ~tag text =
  let open_tag = Printf.sprintf "<%s>" tag in
  let close_tag = Printf.sprintf "</%s>" tag in
  let open_len = String.length open_tag in
  let close_len = String.length close_tag in
  let text_len = String.length text in
  let rec find_start i =
    if i + open_len > text_len then None
    else if String.sub text i open_len = open_tag then
      let content_start = i + open_len in
      find_end content_start content_start
    else find_start (i + 1)
  and find_end content_start j =
    if j + close_len > text_len then None
    else if String.sub text j close_len = close_tag then
      Some (String.sub text content_start (j - content_start))
    else find_end content_start (j + 1)
  in
  find_start 0

(** Parse LLM response containing <hypothesis> and <modified_code> tags.
    Returns Ok (hypothesis, modified_code) or Error reason. *)
let parse_llm_code_response response =
  if String.trim response = "" then
    Result.error "LLM returned empty response"
  else
    match extract_tag ~tag:"hypothesis" response with
    | None -> Result.error "Missing <hypothesis> tag in LLM response"
    | Some h ->
      let hypothesis = String.trim h in
      if hypothesis = "" then Result.error "Empty <hypothesis> tag"
      else
        match extract_tag ~tag:"modified_code" response with
        | None -> Result.error "Missing <modified_code> tag in LLM response"
        | Some code ->
          if String.trim code = "" then Result.error "Empty <modified_code> tag"
          else
            (* Strip all leading/trailing whitespace-only lines *)
            let trimmed =
              let lines = String.split_on_char '\n' code in
              let rec drop_blank = function
                | [] -> []
                | l :: rest ->
                  if String.trim l = "" then drop_blank rest
                  else l :: rest
              in
              let stripped = drop_blank lines in
              let stripped = List.rev (drop_blank (List.rev stripped)) in
              String.concat "\n" stripped
            in
            Result.ok (hypothesis, trimmed)

(** Generate code change by calling Llm_client.complete.
    Returns Ok (hypothesis, new_code) or Error reason. *)
let generate_code_change ~goal ~baseline ~history ~insights
    ~target_file ~file_content ~llm_model =
  let prompt = build_code_change_prompt ~goal ~baseline ~history ~insights
    ~file_content ~target_file in
  match Llm_client.model_spec_of_string llm_model with
  | Result.Error e -> Result.error (Printf.sprintf "Invalid model spec: %s" e)
  | Result.Ok model ->
    let req : Llm_client.completion_request = {
      model;
      messages = [Llm_client.user_msg prompt];
      temperature = 0.7;
      max_tokens = 4096;
      tools = [];
      response_format = `Text;
    } in
    (match Llm_client.complete ~timeout_sec:120 req with
    | Result.Error e -> Result.error (Printf.sprintf "LLM call failed: %s" e)
    | Result.Ok resp -> parse_llm_code_response resp.content)

(* ================================================================ *)
(* Loop State Management                                            *)
(* ================================================================ *)

let create_state ~goal ~metric_fn ?(llm_model = "glm") ~target_file ~cycle_timeout_s ~max_cycles ~workdir () =
  let now = Time_compat.now () in
  {
    loop_id = generate_loop_id ();
    goal;
    metric_fn;
    llm_model;
    target_file;
    status = Running;
    error_message = None;
    current_cycle = 0;
    baseline = 0.0;
    best_score = 0.0;
    best_cycle = 0;
    history = [];
    total_keeps = 0;
    total_discards = 0;
    insights = [];
    start_time = now;
    updated_at = now;
    cycle_timeout_s;
    max_cycles;
    workdir;
  }

(** Append an insight, maintaining FIFO max 10 entries. *)
let add_insight state msg =
  let max_insights = 10 in
  state.insights <- msg :: state.insights;
  if List.length state.insights > max_insights then
    state.insights <- List.filteri (fun i _ -> i < max_insights) state.insights

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
     end;
     add_insight state
       (Printf.sprintf "Cycle %d: %s improved +%.4f" state.current_cycle hypothesis delta)
   | Discard ->
     state.total_discards <- state.total_discards + 1;
     add_insight state
       (Printf.sprintf "Cycle %d: %s no improvement (%.4f)" state.current_cycle hypothesis delta));
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
