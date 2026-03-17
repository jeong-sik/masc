(** Generational Metrics - Evidence for "후대가 더 나은가?"

    Tracks metrics across generations to prove (or disprove) that
    successor agents perform better than their predecessors.

    Key metrics:
    - Task completion rate
    - Error rate
    - Knowledge retention (DNA transfer effectiveness)
    - Token efficiency
*)

(** Task completion record *)
type task_record = {
  generation: int;
  task_id: string;
  completed: bool;
  duration_ms: int;
  error_count: int;
  input_tokens: int;
  output_tokens: int;
  timestamp: float;
}

(** Handoff record *)
type handoff_record = {
  from_generation: int;
  to_generation: int;
  dna_size: int;
  context_ratio: float;
  timestamp: float;
}

(** Knowledge retention test result *)
type retention_test = {
  generation: int;
  question: string;
  expected: string;
  actual: string;
  correct: bool;
  confidence: float;
}

(** Generation summary *)
type generation_summary = {
  generation: int;
  total_tasks: int;
  completed_tasks: int;
  total_errors: int;
  avg_duration_ms: float;
  total_input_tokens: int;
  total_output_tokens: int;
  knowledge_retention: float option;  (* None if not tested *)
}

(** Comparison between generations *)
type generation_comparison = {
  gen_a: int;
  gen_b: int;
  completion_delta: float;      (* positive = B is better *)
  error_delta: float;           (* negative = B is better (fewer errors) *)
  duration_delta: float;        (* negative = B is better (faster) *)
  token_delta: float;           (* negative = B is better (more efficient) *)
  retention_b: float option;
  verdict: string;              (* "improved" | "degraded" | "neutral" *)
}

(** {1 Eio-aware Mutex Guard}

    Follows the dual-mode pattern from prometheus.ml:
    Before Eio runtime starts, runs unlocked (single-threaded).
    After {!enable_eio}, uses [Eio.Mutex]. *)
let mu = Eio.Mutex.create ()
let eio_available = ref false
let enable_eio () = eio_available := true

let with_lock f =
  if !eio_available then
    Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
  else
    f ()

(** In-memory store — also backed by JSONL for restart survival *)
let task_records : task_record list ref = ref []
let handoff_records : handoff_record list ref = ref []
let retention_tests : retention_test list ref = ref []

(** {1 JSONL Persistence}

    Append-only JSONL backup under .masc/metrics/{agent}/
    Used as fallback when in-memory store is empty (post-restart). *)

let metrics_dir () =
  let me_root = Env_config.me_root () in
  Filename.concat me_root ".masc/metrics"

let task_record_to_json (r : task_record) =
  `Assoc [
    ("type", `String "task");
    ("generation", `Int r.generation);
    ("task_id", `String r.task_id);
    ("completed", `Bool r.completed);
    ("duration_ms", `Int r.duration_ms);
    ("error_count", `Int r.error_count);
    ("input_tokens", `Int r.input_tokens);
    ("output_tokens", `Int r.output_tokens);
    ("timestamp", `Float r.timestamp);
  ]

let handoff_record_to_json (r : handoff_record) =
  `Assoc [
    ("type", `String "handoff");
    ("from_generation", `Int r.from_generation);
    ("to_generation", `Int r.to_generation);
    ("dna_size", `Int r.dna_size);
    ("context_ratio", `Float r.context_ratio);
    ("timestamp", `Float r.timestamp);
  ]

let append_jsonl ~agent_name json_line =
  let dir = Filename.concat (metrics_dir ()) agent_name in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir "generations.jsonl" in
  Fs_compat.append_jsonl path json_line

(** Load task records from JSONL file for a given agent. *)
let load_task_records_from_jsonl ~agent_name : task_record list =
  let dir = Filename.concat (metrics_dir ()) agent_name in
  let path = Filename.concat dir "generations.jsonl" in
  let jsons = Fs_compat.load_jsonl path in
  List.filter_map (fun json ->
    try
      let open Yojson.Safe.Util in
      if json |> member "type" |> to_string = "task" then
        Some {
          generation = json |> member "generation" |> to_int;
          task_id = json |> member "task_id" |> to_string;
          completed = json |> member "completed" |> to_bool;
          duration_ms = json |> member "duration_ms" |> to_int;
          error_count = json |> member "error_count" |> to_int;
          input_tokens = json |> member "input_tokens" |> to_int;
          output_tokens = json |> member "output_tokens" |> to_int;
          timestamp = json |> member "timestamp" |> to_float;
        }
      else None
    with
    | Yojson.Safe.Util.Type_error _ -> None
    | exn ->
        Log.Metrics.warn "load_task_records parse: %s" (Printexc.to_string exn);
        None
  ) jsons

(** Record a task completion *)
let record_task ~generation ~task_id ~completed ~duration_ms ~error_count
    ~input_tokens ~output_tokens =
  with_lock (fun () ->
    let record = {
      generation;
      task_id;
      completed;
      duration_ms;
      error_count;
      input_tokens;
      output_tokens;
      timestamp = Time_compat.now ();
    } in
    task_records := record :: !task_records;
    (* JSONL backup — best effort, don't fail the record *)
    (try append_jsonl ~agent_name:"_global" (task_record_to_json record)
     with exn ->
       Log.Metrics.warn "append_jsonl task: %s" (Printexc.to_string exn));
    record)

(** Record a handoff *)
let record_handoff ~from_generation ~to_generation ~dna_size ~context_ratio =
  with_lock (fun () ->
    let record = {
      from_generation;
      to_generation;
      dna_size;
      context_ratio;
      timestamp = Time_compat.now ();
    } in
    handoff_records := record :: !handoff_records;
    (try append_jsonl ~agent_name:"_global" (handoff_record_to_json record)
     with exn ->
       Log.Metrics.warn "append_jsonl handoff: %s" (Printexc.to_string exn));
    record)

(** Record a knowledge retention test *)
let record_retention_test ~generation ~question ~expected ~actual ~confidence =
  with_lock (fun () ->
    let correct = String.lowercase_ascii expected = String.lowercase_ascii actual in
    let record = { generation; question; expected; actual; correct; confidence } in
    retention_tests := record :: !retention_tests;
    record)

(** Internal: summarize without acquiring lock (caller must hold lock) *)
let summarize_generation_unlocked generation =
  (* Fallback: if in-memory is empty, try loading from JSONL *)
  let all_tasks =
    if !task_records = [] then
      (try load_task_records_from_jsonl ~agent_name:"_global"
       with exn ->
         Log.Metrics.warn "load_task_records fallback: %s" (Printexc.to_string exn);
         [])
    else !task_records
  in
  let tasks = List.filter (fun (t : task_record) -> t.generation = generation) all_tasks in
  let total = List.length tasks in
  if total = 0 then None
  else
    let completed = List.filter (fun t -> t.completed) tasks |> List.length in
    let errors = List.fold_left (fun acc t -> acc + t.error_count) 0 tasks in
    let duration_sum = List.fold_left (fun acc t -> acc + t.duration_ms) 0 tasks in
    let input_sum = List.fold_left (fun acc t -> acc + t.input_tokens) 0 tasks in
    let output_sum = List.fold_left (fun acc t -> acc + t.output_tokens) 0 tasks in

    let retention_tests_gen = List.filter (fun (r : retention_test) -> r.generation = generation) !retention_tests in
    let retention =
      if List.length retention_tests_gen = 0 then None
      else
        let correct_count = List.filter (fun r -> r.correct) retention_tests_gen |> List.length in
        Some (float_of_int correct_count /. float_of_int (List.length retention_tests_gen))
    in

    Some {
      generation;
      total_tasks = total;
      completed_tasks = completed;
      total_errors = errors;
      avg_duration_ms = float_of_int duration_sum /. float_of_int total;
      total_input_tokens = input_sum;
      total_output_tokens = output_sum;
      knowledge_retention = retention;
    }

(** Summarize a generation's performance *)
let summarize_generation generation =
  with_lock (fun () -> summarize_generation_unlocked generation)

(** Compare two generations *)
let compare_generations gen_a gen_b =
  with_lock (fun () ->
    match summarize_generation_unlocked gen_a, summarize_generation_unlocked gen_b with
    | None, _ | _, None -> None
    | Some a, Some b ->
        let completion_rate_a = float_of_int a.completed_tasks /. float_of_int a.total_tasks in
        let completion_rate_b = float_of_int b.completed_tasks /. float_of_int b.total_tasks in
        let error_rate_a = float_of_int a.total_errors /. float_of_int a.total_tasks in
        let error_rate_b = float_of_int b.total_errors /. float_of_int b.total_tasks in
        let tokens_per_task_a = float_of_int (a.total_input_tokens + a.total_output_tokens) /. float_of_int a.total_tasks in
        let tokens_per_task_b = float_of_int (b.total_input_tokens + b.total_output_tokens) /. float_of_int b.total_tasks in

        let completion_delta = completion_rate_b -. completion_rate_a in
        let error_delta = error_rate_b -. error_rate_a in
        let duration_delta = b.avg_duration_ms -. a.avg_duration_ms in
        let token_delta = tokens_per_task_b -. tokens_per_task_a in

        (* Verdict: improved if majority of metrics are better *)
        let improvements =
          (if completion_delta > 0.05 then 1 else 0) +
          (if error_delta < -0.05 then 1 else 0) +
          (if duration_delta < 0.0 then 1 else 0) +
          (if token_delta < 0.0 then 1 else 0)
        in
        let verdict =
          if improvements >= 3 then "improved"
          else if improvements <= 1 then "degraded"
          else "neutral"
        in

        Some {
          gen_a;
          gen_b;
          completion_delta;
          error_delta;
          duration_delta;
          token_delta;
          retention_b = b.knowledge_retention;
          verdict;
        })

(** Format comparison as string *)
let format_comparison comp =
  Printf.sprintf
    "Gen %d vs Gen %d:\n\
     - Completion: %+.1f%% (%s)\n\
     - Error rate: %+.1f%% (%s)\n\
     - Duration: %+.0fms (%s)\n\
     - Tokens: %+.0f (%s)\n\
     - Retention: %s\n\
     - Verdict: %s"
    comp.gen_a comp.gen_b
    (comp.completion_delta *. 100.0) (if comp.completion_delta > 0.0 then "better" else "worse")
    (comp.error_delta *. 100.0) (if comp.error_delta < 0.0 then "better" else "worse")
    comp.duration_delta (if comp.duration_delta < 0.0 then "faster" else "slower")
    comp.token_delta (if comp.token_delta < 0.0 then "efficient" else "wasteful")
    (match comp.retention_b with Some r -> Printf.sprintf "%.0f%%" (r *. 100.0) | None -> "not tested")
    comp.verdict

(** Reset all metrics (for testing) *)
let reset () =
  with_lock (fun () ->
    task_records := [];
    handoff_records := [];
    retention_tests := [])

(** Export metrics to JSON *)
let to_json () =
  with_lock (fun () ->
    let tasks_json = `List (List.map (fun (t : task_record) ->
      `Assoc [
        ("generation", `Int t.generation);
        ("task_id", `String t.task_id);
        ("completed", `Bool t.completed);
        ("duration_ms", `Int t.duration_ms);
        ("error_count", `Int t.error_count);
        ("input_tokens", `Int t.input_tokens);
        ("output_tokens", `Int t.output_tokens);
        ("timestamp", `Float t.timestamp);
      ]
    ) !task_records) in

    let handoffs_json = `List (List.map (fun (h : handoff_record) ->
      `Assoc [
        ("from_generation", `Int h.from_generation);
        ("to_generation", `Int h.to_generation);
        ("dna_size", `Int h.dna_size);
        ("context_ratio", `Float h.context_ratio);
        ("timestamp", `Float h.timestamp);
      ]
    ) !handoff_records) in

    `Assoc [
      ("tasks", tasks_json);
      ("handoffs", handoffs_json);
    ])
