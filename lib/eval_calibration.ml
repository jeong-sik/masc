module StringMap = Set_util.StringMap

(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists every anti-rationalization verdict to a date-partitioned JSONL
    store ([data/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label
    attachment for ground-truth tracking and divergence analysis to
    generate few-shot calibration examples for prompt improvement.

    @since #3068 — Harness Design evaluator calibration loop *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type record_type =
  | Verdict_record
  | Label_record

type label_verdict =
  | Approve_label
  | Reject_label

let record_type_to_string = function
  | Verdict_record -> "verdict"
  | Label_record -> "label"

let record_type_of_string = function
  | "verdict" -> Some Verdict_record
  | "label" -> Some Label_record
  | _ -> None

let label_verdict_to_string = function
  | Approve_label -> "approve"
  | Reject_label -> "reject"

let label_verdict_of_string = function
  | "approve" -> Some Approve_label
  | "reject" -> Some Reject_label
  | _ -> None

let verdict_to_string = function
  | Task.Anti_rationalization.Approve _ -> "approve"
  | Task.Anti_rationalization.Reject "" -> "reject"
  | Task.Anti_rationalization.Reject reason -> "reject:" ^ reason

(* The label format stays what it was: one piece for approve, "reject:<reason>"
   for a rejection. Calibration compares verdicts against hand labels, so an
   approval's stated reason has no place in the label and reads back empty. *)
let verdict_of_string raw =
  match String.split_on_char ':' raw with
  | ["approve"] -> Some (Task.Anti_rationalization.Approve "")
  | ["reject"] -> Some (Task.Anti_rationalization.Reject "")
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
  gate : string;
  task_title : string;
}

type calibration_example = {
  task_title : string;
  notes_excerpt : string;         (** Truncated to ~200 chars *)
  correct_verdict : string;       (** "APPROVE" | "REJECT: <reason>" *)
}

(* ================================================================ *)
(* Store                                                             *)
(* ================================================================ *)

let store_ref : Dated_jsonl.t option Atomic.t = Atomic.make None

let base_path () =
  Filename.concat (Env_config_core.base_path ()) "data/verdicts"

let rec get_store () =
  match Atomic.get store_ref with
  | Some s -> s
  | None ->
    let s = Dated_jsonl.create ~base_dir:(base_path ()) () in
    if Atomic.compare_and_set store_ref None (Some s)
    then s
    else
      (* Another domain published the process-wide store while this domain
         created its candidate.  All writers must use that single instance so
         Dated_jsonl's per-store serialization remains authoritative. *)
      get_store ()

module For_testing = struct
  let reset_store () = Atomic.set store_ref None
  let set_store ~base_dir =
    Atomic.set store_ref (Some (Dated_jsonl.create ~base_dir ()))
end


(* ================================================================ *)
(* Hashing                                                           *)
(* ================================================================ *)

let notes_hash ~(task_title : string) ~(notes : string) : string =
  let input = task_title ^ "\n" ^ notes in
  Digestif.SHA256.(digest_string input |> to_hex)

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

let record_verdict
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
      ; fallback_reason = result.fallback_reason
      ; timestamp = Unix.gettimeofday ()
      }
    in
    Dated_jsonl.append (get_store ()) (verdict_record_to_json record)

let record_human_label
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
  Dated_jsonl.append (get_store ()) (label_record_to_json record)

(* ================================================================ *)
(* JSON deserialization (for analysis)                                *)
(* ================================================================ *)

let string_field json key =
  Json_util.get_string_with_default json ~key ~default:""

(* ================================================================ *)
(* Divergence analysis                                               *)
(* ================================================================ *)

(* Row bounds for the two windowed calibration readers. Both branches of each
   reader use its bound: the filtered branch previously had none. *)
let divergence_scan_rows = 1000
let calibration_scan_rows = 5000

let find_divergences ?(since = "") ?(until = "") () : divergence list =
  let store = get_store () in
  let records =
    if since = "" && until = "" then
      Dated_jsonl.read_recent store divergence_scan_rows
    else
      (* Same bound as the unfiltered branch above. [read_range] carries no
         row bound, so supplying a date -- which narrows the request -- used to
         remove the cap, and a one-sided date widens it further because the
         missing side is filled with 2020-01-01 / 2099-12-31 below. *)
      let s = if since = "" then "2020-01-01" else since in
      let u = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range_recent store ~since:s ~until:u divergence_scan_rows
  in
  (* Separate verdicts and labels *)
  let (verdicts, labels) : Yojson.Safe.t StringMap.t * Yojson.Safe.t StringMap.t =
    List.fold_left (fun (vs, ls) json ->
      let rt = string_field json "record_type" |> record_type_of_string in
      let hash = string_field json "notes_hash" in
      match rt with
      | Some Verdict_record -> (StringMap.add hash json vs, ls)
      | Some Label_record -> (vs, StringMap.add hash json ls)
      | None -> (vs, ls)
    ) (StringMap.empty, StringMap.empty) records
  in
  (* Find disagreements *)
  StringMap.fold (fun hash v_json acc ->
    match StringMap.find_opt hash labels with
    | None -> acc
    | Some l_json ->
      (match
         verdict_of_string (string_field v_json "verdict"),
         label_verdict_of_string (string_field l_json "human_verdict")
       with
      | Some ev, Some hv ->
          if label_verdict_of_verdict ev <> hv then
            {
              notes_hash = hash;
              evaluator_verdict = ev;
              human_verdict = hv;
              gate = string_field v_json "gate";
              task_title = string_field v_json "task_title";
            }
            :: acc
          else
            acc
      | _ -> acc)
  ) verdicts []

(* ================================================================ *)
(* Few-shot example selection                                        *)
(* ================================================================ *)

let select_examples ~(max_examples : int) : calibration_example list =
  let divs = find_divergences () in
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

let calibration_stats ?(since = "") ?(until = "") () : Yojson.Safe.t =
  let store = get_store () in
  let records =
    if since = "" && until = "" then
      Dated_jsonl.read_recent store calibration_scan_rows
    else
      (* Same bound as the unfiltered branch; see [find_divergences]. *)
      let s = if since = "" then "2020-01-01" else since in
      let u = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range_recent store ~since:s ~until:u calibration_scan_rows
  in
  let max_failure_reasons = 5 in
  let evaluator_failure_tags =
    [ Task.Anti_rationalization.Invalid_verdict
    ; Task.Anti_rationalization.Evaluator_unavailable
    ]
    |> List.map Task.Anti_rationalization.gate_to_string
  in
  (* Single fold to accumulate all counters and maps immutably *)
  let total_verdicts, approve_count, reject_count,
      gate_counts, verdict_hashes, labeled_hashes,
      recent_fallback_reasons,
      verdicts_with_generator, cross_model_match =
    List.fold_left (fun (tv, ac, rc, gc, vh, lh, fbr, vwg, cmm) json ->
      let rt = string_field json "record_type" |> record_type_of_string in
      let hash = string_field json "notes_hash" in
      match rt with
      | Some Verdict_record -> begin
          match verdict_of_string (string_field json "verdict") with
          | Some v ->
              let ac', rc' =
                match v with
                | Task.Anti_rationalization.Approve _ -> ac + 1, rc
                | Task.Anti_rationalization.Reject _ -> ac, rc + 1
              in
              let gate = string_field json "gate" in
              let prev = Option.value ~default:0 (StringMap.find_opt gate gc) in
              let gc' = StringMap.add gate (prev + 1) gc in
              let vh' = StringMap.add hash v vh in
              let ev_runtime = string_field json "evaluator_runtime" in
              let gen_runtime = string_field json "generator_runtime" in
              let vwg', cmm' =
                if gen_runtime <> "" && ev_runtime <> "" then
                  vwg + 1,
                  (if not (String.equal gen_runtime ev_runtime) then cmm + 1 else cmm)
                else
                  vwg, cmm
              in
              let fbr' =
                if List.mem gate evaluator_failure_tags
                   && List.length fbr < max_failure_reasons
                then
                  let reason = string_field json "fallback_reason" in
                  if reason <> "" then reason :: fbr else fbr
                else
                  fbr
              in
              (tv + 1, ac', rc', gc', vh', lh, fbr', vwg', cmm')
          | None ->
              (tv, ac, rc, gc, vh, lh, fbr, vwg, cmm)
        end
      | Some Label_record -> begin
          match label_verdict_of_string (string_field json "human_verdict") with
          | Some v ->
              (tv, ac, rc, gc, vh, StringMap.add hash v lh, fbr, vwg, cmm)
          | None ->
              (tv, ac, rc, gc, vh, lh, fbr, vwg, cmm)
        end
      | None ->
          (tv, ac, rc, gc, vh, lh, fbr, vwg, cmm)
    ) (0, 0, 0, StringMap.empty, StringMap.empty, StringMap.empty,
       [], 0, 0) records
  in
  (* Count divergences *)
  let false_pos, false_neg, agree =
    StringMap.fold (fun hash ev (fp, fn, ag) ->
      match StringMap.find_opt hash labeled_hashes with
      | None -> (fp, fn, ag)
      | Some hv ->
          if label_verdict_of_verdict ev = hv then
            (fp, fn, ag + 1)
          else (
            (* Every disagreement pair is written out. The wildcard this
               replaces asserted "false negative" for anything that was not
               (Approve, Reject_label); a third label_verdict would have been
               counted as a false negative and quietly lowered
               agreement_rate. Listing the pairs makes the compiler ask
               instead. *)
            match ev, hv with
            | Task.Anti_rationalization.Approve _, Reject_label -> (fp + 1, fn, ag)
            | Task.Anti_rationalization.Reject _, Approve_label -> (fp, fn + 1, ag)
            | Task.Anti_rationalization.Approve _, Approve_label
            | Task.Anti_rationalization.Reject _, Reject_label ->
                (* [label_verdict_of_verdict ev = hv] already returned above. *)
                (fp, fn, ag + 1))
    ) verdict_hashes (0, 0, 0)
  in
  let labeled_total = false_pos + false_neg + agree in
  let agreement_rate =
    if labeled_total = 0 then 0.0
    else float_of_int agree /. float_of_int labeled_total
  in
  let gate_json = StringMap.bindings gate_counts |> List.map (fun (k, v) -> (k, `Int v)) in
  let fallback_count =
    List.fold_left
      (fun total gate ->
         total + Option.value ~default:0 (StringMap.find_opt gate gate_counts))
      0
      evaluator_failure_tags
  in
  let cross_model_rate =
    if verdicts_with_generator = 0 then 0.0
    else float_of_int cross_model_match /. float_of_int verdicts_with_generator
  in
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
    ("cross_model_match_count", `Int cross_model_match);
    ("cross_model_rate", `Float cross_model_rate);
    ("recent_fallback_reasons",
     `List (List.rev_map (fun s -> `String s) recent_fallback_reasons));
  ]
