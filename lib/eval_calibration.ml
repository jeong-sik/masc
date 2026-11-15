module StringMap = Set_util.StringMap

(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists every anti-rationalization verdict to a date-partitioned JSONL
    store ([.masc/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label
    attachment for ground-truth tracking and divergence analysis to
    generate few-shot calibration examples for prompt improvement.

    @since #3068 — Harness Design evaluator calibration loop *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type record_type =
  | Verdict_record
  | Label_record
[@@deriving enumerate]

type label_verdict =
  | Approve_label
  | Reject_label
[@@deriving enumerate]

let record_type_to_string = function
  | Verdict_record -> "verdict"
  | Label_record -> "label"

let record_type_of_string s = List.find_opt (fun v -> String.equal (record_type_to_string v) s) all_of_record_type

let label_verdict_to_string = function
  | Approve_label -> "approve"
  | Reject_label -> "reject"

let label_verdict_of_string s = List.find_opt (fun v -> String.equal (label_verdict_to_string v) s) all_of_label_verdict

let verdict_to_string = function
  | Task.Anti_rationalization.Approve "" -> "approve"
  | Task.Anti_rationalization.Approve reason -> "approve:" ^ reason
  | Task.Anti_rationalization.Reject "" -> "reject"
  | Task.Anti_rationalization.Reject reason -> "reject:" ^ reason

(* Machine verdicts preserve stated reasons for both outcomes:
   "approve" / "approve:<reason>" and "reject" / "reject:<reason>". *)
let verdict_of_string raw =
  match String.split_on_char ':' raw with
  | "approve" :: reason_parts ->
      Some (Task.Anti_rationalization.Approve (String.concat ":" reason_parts))
  | "reject" :: reason_parts ->
      Some (Task.Anti_rationalization.Reject (String.concat ":" reason_parts))
  | _ -> None

let label_verdict_of_verdict = function
  | Task.Anti_rationalization.Approve _ -> Approve_label
  | Task.Anti_rationalization.Reject _ -> Reject_label

type verdict_record = {
  record_type : record_type;
  notes_hash : string;            (** SHA256(task_title ^ "\n" ^ completion_notes) *)
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : Task.Anti_rationalization.verdict;
  gate : Task.Anti_rationalization.gate;  (** Typed gate — was stringly-typed *)
  evaluator_runtime : string;
  generator_runtime : string option;
  producer_execution : Runtime_response_identity.t option;
  evaluator_execution : Runtime_response_identity.t option;
  fallback_reason : string option; (** Evaluator or verdict-format failure detail. *)
  timestamp : float;
}

type label_record = {
  record_type : record_type;
  notes_hash : string;
  human_verdict : label_verdict;
  labeler : string;
  reason : string;
  timestamp : float;
}

type divergence = {
  notes_hash : string;
  evaluator_verdict : Task.Anti_rationalization.verdict;
  human_verdict : label_verdict;
  gate : Task.Anti_rationalization.gate;
  task_title : string;
}

type stored_record =
  | Verdict of verdict_record
  | Label of label_record

type window = {
  verdicts : verdict_record list;
  labels : label_record list;
  unreadable_rows : int;
}

type divergence_scan = {
  divergences : divergence list;
  unreadable_rows : int;
}

type calibration_example = {
  task_title : string;
  notes_excerpt : string;         (** Truncated to ~200 chars *)
  correct_verdict : string;       (** "APPROVE" | "REJECT: <reason>" *)
}

(* ================================================================ *)
(* Store                                                             *)
(* ================================================================ *)

(* Appends to one directory share the mutex [Dated_jsonl.open_store] keeps
   per store directory, so opening the store on each call keeps them
   serialized. *)
let store ~base_path =
  Dated_jsonl.open_store
    Dated_jsonl.Store.(at (root_of_base_path ~base_path) Root.Verdicts)


(* ================================================================ *)
(* Hashing                                                           *)
(* ================================================================ *)

let notes_hash ~(task_title : string) ~(notes : string) : string =
  let input = task_title ^ "\n" ^ notes in
  Agent_core_sha256.(digest_string input |> to_hex)

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let verdict_record_to_json (r : verdict_record) : Yojson.Safe.t =
  let base = [
    ("record_type", `String (record_type_to_string r.record_type));
    ("notes_hash", `String r.notes_hash);
    ("task_id", `String r.task_id);
    ("task_title", `String r.task_title);
    ("agent_name", `String r.agent_name);
    ("verdict", `String (verdict_to_string r.verdict));
    ("gate", `String (Task.Anti_rationalization.gate_to_string r.gate));
    ("evaluator_runtime", `String r.evaluator_runtime);
    ("generator_runtime", Json_util.string_opt_to_json r.generator_runtime);
    ("producer_execution", (match r.producer_execution with None -> `Null | Some value -> Runtime_response_identity.to_yojson value));
    ("evaluator_execution", (match r.evaluator_execution with None -> `Null | Some value -> Runtime_response_identity.to_yojson value));
    ("timestamp", `Float r.timestamp);
  ] in
  let extra = match r.fallback_reason with
    | Some reason -> [("fallback_reason", `String reason)]
    | None -> []
  in
  `Assoc (base @ extra)

let label_record_to_json (r : label_record) : Yojson.Safe.t =
  `Assoc [
    ("record_type", `String (record_type_to_string r.record_type));
    ("notes_hash", `String r.notes_hash);
    ("human_verdict", `String (label_verdict_to_string r.human_verdict));
    ("labeler", `String r.labeler);
    ("reason", `String r.reason);
    ("timestamp", `Float r.timestamp);
  ]

(* ================================================================ *)
(* Record writing                                                    *)
(* ================================================================ *)

(* The observer is called after every appended verdict or label record, with
   the workspace the store belongs to, under no lock of this module. *)
let written_observer : (base_path:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ -> ())

let install_written_observer observer = Atomic.set written_observer observer

let identity_matching predicate identity =
  Option.bind identity (fun identity -> if predicate identity then Some identity else None)

let record_verdict
    ?producer_execution
    ~(base_path : string)
    ~(task_id : string)
    ~(req : Task.Anti_rationalization.review_request)
    ~(result : Task.Anti_rationalization.review_result)
    () : unit =
  match result.verdict with
  | None -> ()
  | Some verdict ->
    let hash = notes_hash ~task_title:req.task_title ~notes:req.completion_notes in
    let record =
      { record_type = Verdict_record
      ; notes_hash = hash
      ; task_id
      ; task_title = req.task_title
      ; agent_name = req.agent_name
      ; verdict
      ; gate = result.gate
      ; evaluator_runtime = result.evaluator_runtime
      ; generator_runtime = result.generator_runtime
      ; producer_execution = identity_matching
          (fun identity -> String.equal identity.Runtime_response_identity.actor req.agent_name) producer_execution
      ; evaluator_execution = identity_matching
          (fun identity -> String.equal identity.Runtime_response_identity.runtime_id result.evaluator_runtime) result.evaluator_execution
      ; fallback_reason = result.fallback_reason
      ; timestamp = Unix.gettimeofday ()
      }
    in
    Dated_jsonl.append (store ~base_path) (verdict_record_to_json record);
    (Atomic.get written_observer) ~base_path

let record_human_label
    ~(base_path : string)
    ~(notes_hash : string)
    ~(human_verdict : label_verdict)
    ~(labeler : string)
    ~(reason : string) : unit =
  let record = {
    record_type = Label_record;
    notes_hash;
    human_verdict;
    labeler;
    reason;
    timestamp = Unix.gettimeofday ();
  } in
  Dated_jsonl.append (store ~base_path) (label_record_to_json record);
  (Atomic.get written_observer) ~base_path

(* ================================================================ *)
(* JSON deserialization                                              *)
(* ================================================================ *)

(* [stored_record_of_json] is the inverse of [verdict_record_to_json] and
   [label_record_to_json], and the only way a stored row becomes a record. A
   key is read the way its writer writes it: always-written keys are required,
   [fallback_reason] is absent for [None], the nullable keys are [null] for
   [None]. A row neither writer produces is an [Error] naming the first key
   that does not fit. *)

let ( let* ) = Result.bind

let field fields name =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [ _, value ] -> Ok (Some value)
  | [] -> Ok None
  | _ :: _ :: _ -> Error (Printf.sprintf "%s: written more than once" name)

let required_field fields name =
  let* value = field fields name in
  match value with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s: missing" name)

let string_field fields name =
  let* value = required_field fields name in
  match value with
  | `String text -> Ok text
  | _ -> Error (Printf.sprintf "%s: not a string" name)

let timestamp_field fields =
  let* value = required_field fields "timestamp" in
  match value with
  | `Float seconds -> Ok seconds
  | _ -> Error "timestamp: not a float"

let nullable_string_field fields name =
  let* value = required_field fields name in
  match value with
  | `Null -> Ok None
  | `String text -> Ok (Some text)
  | _ -> Error (Printf.sprintf "%s: neither null nor a string" name)

let nullable_identity_field fields name =
  let* value = required_field fields name in
  match value with
  | `Null -> Ok None
  | json ->
    (match Runtime_response_identity.of_yojson json with
     | Ok identity -> Ok (Some identity)
     | Error detail -> Error (Printf.sprintf "%s: %s" name detail))

let fallback_reason_field fields =
  let* value = field fields "fallback_reason" in
  match value with
  | None -> Ok None
  | Some (`String reason) -> Ok (Some reason)
  | Some _ -> Error "fallback_reason: not a string"

let verdict_record_of_fields fields : (verdict_record, string) result =
  let* notes_hash = string_field fields "notes_hash" in
  let* task_id = string_field fields "task_id" in
  let* task_title = string_field fields "task_title" in
  let* agent_name = string_field fields "agent_name" in
  let* raw_verdict = string_field fields "verdict" in
  let* verdict =
    match verdict_of_string raw_verdict with
    | Some verdict -> Ok verdict
    | None -> Error (Printf.sprintf "verdict: unknown value %S" raw_verdict)
  in
  let* raw_gate = string_field fields "gate" in
  let* gate =
    Task.Anti_rationalization.gate_of_string raw_gate
    |> Result.map_error (fun detail -> "gate: " ^ detail)
  in
  let* evaluator_runtime = string_field fields "evaluator_runtime" in
  let* generator_runtime = nullable_string_field fields "generator_runtime" in
  let* producer_execution = nullable_identity_field fields "producer_execution" in
  let* evaluator_execution = nullable_identity_field fields "evaluator_execution" in
  let* fallback_reason = fallback_reason_field fields in
  let* timestamp = timestamp_field fields in
  Ok
    { record_type = Verdict_record
    ; notes_hash
    ; task_id
    ; task_title
    ; agent_name
    ; verdict
    ; gate
    ; evaluator_runtime
    ; generator_runtime
    ; producer_execution
    ; evaluator_execution
    ; fallback_reason
    ; timestamp
    }

let label_record_of_fields fields : (label_record, string) result =
  let* notes_hash = string_field fields "notes_hash" in
  let* raw_verdict = string_field fields "human_verdict" in
  let* human_verdict =
    match label_verdict_of_string raw_verdict with
    | Some verdict -> Ok verdict
    | None -> Error (Printf.sprintf "human_verdict: unknown value %S" raw_verdict)
  in
  let* labeler = string_field fields "labeler" in
  let* reason = string_field fields "reason" in
  let* timestamp = timestamp_field fields in
  Ok { record_type = Label_record; notes_hash; human_verdict; labeler; reason; timestamp }

let stored_record_of_json (json : Yojson.Safe.t) : (stored_record, string) result =
  match json with
  | `Assoc fields ->
    let* raw_type = string_field fields "record_type" in
    (match record_type_of_string raw_type with
     | Some Verdict_record ->
       Result.map (fun record -> Verdict record) (verdict_record_of_fields fields)
     | Some Label_record ->
       Result.map (fun record -> Label record) (label_record_of_fields fields)
     | None -> Error (Printf.sprintf "record_type: unknown value %S" raw_type))
  | _ -> Error "row is not an object"

(* ================================================================ *)
(* Window reader                                                     *)
(* ================================================================ *)

(* Row bounds for the two windowed calibration readers. *)
let divergence_scan_rows = 1000
let calibration_scan_rows = 5000

(* Both branches read at most [max_rows] rows. [read_range] carries no row
   bound, so supplying a date -- which narrows the request -- would remove the
   cap, and a one-sided date widens it further because the missing side is
   filled with 2020-01-01 / 2099-12-31 below. *)
let read_window ?(since = "") ?(until = "") ~base_path ~max_rows () : window =
  let store = store ~base_path in
  let decode json = Some (stored_record_of_json json) in
  let rows =
    if since = "" && until = "" then
      Dated_jsonl.filter_map_recent store max_rows ~f:decode
    else
      let s = if since = "" then "2020-01-01" else since in
      let u = if until = "" then "2099-12-31" else until in
      Dated_jsonl.filter_map_range_recent store ~since:s ~until:u max_rows ~f:decode
  in
  let verdicts, labels, unreadable_rows =
    List.fold_left
      (fun (verdicts, labels, unreadable_rows) row ->
         match row with
         | Ok (Verdict record) -> record :: verdicts, labels, unreadable_rows
         | Ok (Label record) -> verdicts, record :: labels, unreadable_rows
         | Error (_ : string) -> verdicts, labels, unreadable_rows + 1)
      ([], [], 0)
      rows
  in
  { verdicts = List.rev verdicts; labels = List.rev labels; unreadable_rows }

(* Later rows replace earlier ones under the same hash: the window is
   chronological, so each hash keeps its newest record. *)
let newest_by_hash (type a) (hash_of : a -> string) (records : a list) : a StringMap.t =
  List.fold_left
    (fun newest record -> StringMap.add (hash_of record) record newest)
    StringMap.empty
    records

(* ================================================================ *)
(* Divergence analysis                                               *)
(* ================================================================ *)

let find_divergences ?since ?until ~base_path () : divergence_scan =
  let window = read_window ?since ?until ~base_path ~max_rows:divergence_scan_rows () in
  let verdicts =
    newest_by_hash (fun (record : verdict_record) -> record.notes_hash) window.verdicts
  in
  let labels =
    newest_by_hash (fun (record : label_record) -> record.notes_hash) window.labels
  in
  let divergences =
    StringMap.fold (fun hash (verdict : verdict_record) acc ->
      match StringMap.find_opt hash labels with
      | None -> acc
      | Some (label : label_record) ->
        if label_verdict_of_verdict verdict.verdict <> label.human_verdict then
          {
            notes_hash = hash;
            evaluator_verdict = verdict.verdict;
            human_verdict = label.human_verdict;
            gate = verdict.gate;
            task_title = verdict.task_title;
          }
          :: acc
        else
          acc
    ) verdicts []
  in
  { divergences; unreadable_rows = window.unreadable_rows }

(* ================================================================ *)
(* Few-shot example selection                                        *)
(* ================================================================ *)

let select_examples ~base_path ~(max_examples : int) : calibration_example list =
  let divs = (find_divergences ~base_path ()).divergences in
  (* Prioritize false positives: evaluator approved but human rejected *)
  let false_positives, others = List.partition (fun d ->
    match d.evaluator_verdict, d.human_verdict with
    | Task.Anti_rationalization.Approve _, Reject_label -> true
    | Task.Anti_rationalization.Approve _, Approve_label -> false
    | Task.Anti_rationalization.Reject _, Reject_label -> false
    | Task.Anti_rationalization.Reject _, Approve_label -> false
  ) divs in
  let sorted = false_positives @ others in
  let limited =
    if List.length sorted <= max_examples then sorted
    else List.filteri (fun i _ -> i < max_examples) sorted
  in
  List.map
    (fun d ->
       let correct =
         match d.human_verdict with
         | Approve_label -> "APPROVE"
         | Reject_label ->
           (* The label a divergence example carries is prompt prose; it lives in
              eval.calibration.few_shot.md beside the template that renders it. *)
           (match
              Prompt_registry.render_prompt_template
                Prompt_names.eval_calibration_few_shot_rejected_label
                []
            with
            | Ok text -> String.trim text
            | Error detail ->
              invalid_arg
                (Printf.sprintf
                   "missing or invalid calibration prompt %s: %s"
                   Prompt_names.eval_calibration_few_shot_rejected_label
                   detail))
       in
       { task_title = d.task_title
       ; notes_excerpt = "(see task notes)"
       ; correct_verdict = correct
       })
    limited
;;

let format_few_shot_block (examples : calibration_example list) : string =
  if examples = [] then ""
  else
    let render key vars =
      match Prompt_registry.render_prompt_template key vars with
      | Ok prompt -> String.trim prompt
      | Error detail ->
          invalid_arg (Printf.sprintf "missing or invalid calibration prompt %s: %s" key detail)
    in
    let examples =
      examples
      |> List.mapi (fun i ex ->
             render Prompt_names.eval_calibration_few_shot_example
               [ "index", string_of_int (i + 1)
               ; "task_title", ex.task_title
               ; "notes_excerpt", ex.notes_excerpt
               ; "correct_verdict", ex.correct_verdict ])
      |> String.concat "\n\n"
    in
    render Prompt_names.eval_calibration_few_shot [ "examples", examples ]


(* ================================================================ *)
(* Statistics                                                        *)
(* ================================================================ *)

let calibration_stats ?since ?until ~base_path () : Yojson.Safe.t =
  let window = read_window ?since ?until ~base_path ~max_rows:calibration_scan_rows () in
  let max_failure_reasons = 5 in
  (* Single fold to accumulate all counters and maps immutably *)
  let approve_count, reject_count,
      gate_counts, fallback_count,
      recent_fallback_reasons,
      verdicts_with_generator, distinct_runtime_count =
    List.fold_left (fun (ac, rc, gc, fc, fbr, vwg, drc) (record : verdict_record) ->
      let ac', rc' =
        match record.verdict with
        | Task.Anti_rationalization.Approve _ -> ac + 1, rc
        | Task.Anti_rationalization.Reject _ -> ac, rc + 1
      in
      let gate = Task.Anti_rationalization.gate_to_string record.gate in
      let prev = Option.value ~default:0 (StringMap.find_opt gate gc) in
      let gc' = StringMap.add gate (prev + 1) gc in
      let vwg', drc' =
        match record.generator_runtime with
        | Some gen_runtime when gen_runtime <> "" && record.evaluator_runtime <> "" ->
          vwg + 1,
          (if not (String.equal gen_runtime record.evaluator_runtime) then drc + 1 else drc)
        | Some _ | None -> vwg, drc
      in
      let evaluator_failed =
        match record.gate with
        | Task.Anti_rationalization.Invalid_verdict
        | Task.Anti_rationalization.Evaluator_unavailable -> true
        | Task.Anti_rationalization.Structured_tool -> false
      in
      let fc' = if evaluator_failed then fc + 1 else fc in
      let fbr' =
        if evaluator_failed && List.length fbr < max_failure_reasons
        then (
          match record.fallback_reason with
          | Some reason when reason <> "" -> reason :: fbr
          | Some _ | None -> fbr)
        else fbr
      in
      (ac', rc', gc', fc', fbr', vwg', drc')
    ) (0, 0, StringMap.empty, 0, [], 0, 0) window.verdicts
  in
  let total_verdicts = List.length window.verdicts in
  let verdict_hashes =
    newest_by_hash (fun (record : verdict_record) -> record.notes_hash) window.verdicts
  in
  let labeled_hashes =
    newest_by_hash (fun (record : label_record) -> record.notes_hash) window.labels
  in
  (* Count divergences *)
  let false_pos, false_neg, agree =
    StringMap.fold (fun hash (verdict : verdict_record) (fp, fn, ag) ->
      match StringMap.find_opt hash labeled_hashes with
      | None -> (fp, fn, ag)
      | Some (label : label_record) ->
          (* Every pair is written out, so a third label_verdict makes the
             compiler ask where it counts instead of landing in a wildcard. *)
          (match verdict.verdict, label.human_verdict with
           | Task.Anti_rationalization.Approve _, Reject_label -> (fp + 1, fn, ag)
           | Task.Anti_rationalization.Reject _, Approve_label -> (fp, fn + 1, ag)
           | Task.Anti_rationalization.Approve _, Approve_label
           | Task.Anti_rationalization.Reject _, Reject_label -> (fp, fn, ag + 1))
    ) verdict_hashes (0, 0, 0)
  in
  let labeled_total = false_pos + false_neg + agree in
  let agreement_rate =
    if labeled_total = 0 then 0.0
    else float_of_int agree /. float_of_int labeled_total
  in
  let gate_json = StringMap.bindings gate_counts |> List.map (fun (k, v) -> (k, `Int v)) in
  let distinct_runtime_rate =
    if verdicts_with_generator = 0 then `Null
    else `Float (float_of_int distinct_runtime_count /. float_of_int verdicts_with_generator)
  in
  let identity_observation =
    List.map (fun (record : verdict_record) ->
      let producer_identity =
        record.producer_execution
        |> identity_matching (fun identity -> String.equal identity.Runtime_response_identity.actor record.agent_name) in
      let evaluator_identity =
        record.evaluator_execution
        |> identity_matching (fun identity -> String.equal identity.Runtime_response_identity.runtime_id record.evaluator_runtime) in
      (producer_identity, evaluator_identity)) window.verdicts
    |> Runtime_response_identity.summarize_pairs
    |> Runtime_response_identity.pair_summary_to_yojson in
  `Assoc [
    ("total_verdicts", `Int total_verdicts);
    ("approve_count", `Int approve_count);
    ("reject_count", `Int reject_count);
    ("gate_distribution", `Assoc gate_json);
    ("labeled_count", `Int labeled_total);
    ("false_positive_count", `Int false_pos);
    ("false_negative_count", `Int false_neg);
    ("agreement_rate", `Float agreement_rate);
    ("fallback_count", `Int fallback_count);
    ("verdicts_with_generator_runtime", `Int verdicts_with_generator);
    ("distinct_runtime_count", `Int distinct_runtime_count);
    ("distinct_runtime_rate", distinct_runtime_rate);
    ("model_identity_observation", identity_observation);
    ("recent_fallback_reasons",
     `List (List.rev_map (fun s -> `String s) recent_fallback_reasons));
    ("unreadable_record_count", `Int window.unreadable_rows);
  ]
