module StringMap = Map.Make (String)

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
  | Anti_rationalization.Approve -> "approve"
  | Anti_rationalization.Reject "" -> "reject"
  | Anti_rationalization.Reject reason -> "reject:" ^ reason

let verdict_of_string raw =
  match String.split_on_char ':' raw with
  | ["approve"] -> Some Anti_rationalization.Approve
  | ["reject"] -> Some (Anti_rationalization.Reject "")
  | "reject" :: reason_parts ->
      Some (Anti_rationalization.Reject (String.concat ":" reason_parts))
  | _ -> None

let label_verdict_of_verdict = function
  | Anti_rationalization.Approve -> Approve_label
  | Anti_rationalization.Reject _ -> Reject_label

type verdict_record = {
  record_type : record_type;
  notes_hash : string;            (** SHA256(task_title ^ "\n" ^ completion_notes) *)
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : Anti_rationalization.verdict;
  gate : Anti_rationalization.gate;  (** Typed gate — was stringly-typed *)
  evaluator_cascade : string;
  generator_cascade : string option;
  fallback_reason : string option; (** Error message when gate=Fallback *)
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
  evaluator_verdict : Anti_rationalization.verdict;
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

let store_ref : Dated_jsonl.t option ref = ref None

let base_path () =
  Filename.concat (Env_config_core.base_path ()) "data/verdicts"

let get_store () =
  match !store_ref with
  | Some s -> s
  | None ->
    let s = Dated_jsonl.create ~base_dir:(base_path ()) () in
    store_ref := Some s;
    s

(** Reset the store reference.  For testing only. *)
let reset_store_for_testing () = store_ref := None

(** Create a store with a custom base directory.  For testing only. *)
let set_store_for_testing ~base_dir =
  store_ref := Some (Dated_jsonl.create ~base_dir ())

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
    ("gate", `String (Anti_rationalization.gate_to_string r.gate));
    ("evaluator_cascade", `String r.evaluator_cascade);
    ("generator_cascade", Json_util.string_opt_to_json r.generator_cascade);
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
(* OAS Harness.verdict conversion (#3165)                            *)
(* ================================================================ *)

(** Convert a MASC [verdict_record] to an OAS [Harness.verdict].
    Maps "approve" → passed=true, "reject:*" → passed=false.
    The gate name is recorded as evidence for traceability. *)
let to_harness_verdict (r : verdict_record) : Agent_sdk.Harness.verdict =
  let passed =
    match r.verdict with
    | Anti_rationalization.Approve -> true
    | Anti_rationalization.Reject _ -> false
  in
  let score = if passed then Some 1.0 else Some 0.0 in
  let evidence = [
    Printf.sprintf "gate=%s" (Anti_rationalization.gate_to_string r.gate);
    Printf.sprintf "evaluator=%s" r.evaluator_cascade;
    Printf.sprintf "task_id=%s" r.task_id;
  ] in
  let detail =
    if passed then
      None
    else
      Some
        (Printf.sprintf "rejected at %s gate: %s"
           (Anti_rationalization.gate_to_string r.gate)
           (verdict_to_string r.verdict))
  in
  { Agent_sdk.Harness.passed; score; evidence; detail }

(* ================================================================ *)
(* Record writing                                                    *)
(* ================================================================ *)

let record_verdict
    ~(task_id : string)
    ~(req : Anti_rationalization.review_request)
    ~(result : Anti_rationalization.review_result)
    ?(on_harness_verdict : (Agent_sdk.Harness.verdict -> unit) option)
    () : unit =
  let hash = notes_hash ~task_title:req.task_title ~notes:req.completion_notes in
  let record = {
    record_type = Verdict_record;
    notes_hash = hash;
    task_id;
    task_title = req.task_title;
    agent_name = req.agent_name;
    verdict = result.verdict;
    gate = result.gate;
    evaluator_cascade = result.evaluator_cascade;
    generator_cascade = result.generator_cascade;
    fallback_reason = result.fallback_reason;
    timestamp = Unix.gettimeofday ();
  } in
  Dated_jsonl.append (get_store ()) (verdict_record_to_json record);
  match on_harness_verdict with
  | Some cb ->
    (try cb (to_harness_verdict record)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Harness.warn "[eval_calibration] on_harness_verdict callback failed: %s"
         (Printexc.to_string exn))
  | None -> ()

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
  try Yojson.Safe.Util.(json |> member key |> to_string)
  with Yojson.Safe.Util.Type_error _ | Not_found -> ""

(* ================================================================ *)
(* Divergence analysis                                               *)
(* ================================================================ *)

let find_divergences ?(since = "") ?(until = "") () : divergence list =
  let store = get_store () in
  let records =
    if since = "" && until = "" then
      Dated_jsonl.read_recent store 1000
    else
      let s = if since = "" then "2020-01-01" else since in
      let u = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range store ~since:s ~until:u
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
    | Anti_rationalization.Approve, Reject_label -> true
    | _ -> false
  ) divs in
  let sorted = false_positives @ others in
  let limited =
    if List.length sorted <= max_examples then sorted
    else List.filteri (fun i _ -> i < max_examples) sorted
  in
  List.map (fun d ->
    let correct =
      match d.human_verdict with
      | Approve_label -> "APPROVE"
      | Reject_label -> "REJECT: evaluator incorrectly approved"
    in
    { task_title = d.task_title;
      notes_excerpt = "(see task notes)";
      correct_verdict = correct }
  ) limited

let format_few_shot_block (examples : calibration_example list) : string =
  if examples = [] then ""
  else
    let lines = List.mapi (fun i ex ->
      Printf.sprintf "Example %d:\n  Task: %s\n  Notes: %s\n  Correct verdict: %s"
        (i + 1) ex.task_title ex.notes_excerpt ex.correct_verdict
    ) examples in
    "Here are examples of correct verdicts for calibration:\n\n"
    ^ String.concat "\n\n" lines


(* ================================================================ *)
(* Statistics                                                        *)
(* ================================================================ *)

let calibration_stats ?(since = "") ?(until = "") () : Yojson.Safe.t =
  let store = get_store () in
  let records =
    if since = "" && until = "" then
      Dated_jsonl.read_recent store 5000
    else
      let s = if since = "" then "2020-01-01" else since in
      let u = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range store ~since:s ~until:u
  in
  let max_fallback_reasons = 5 in
  let fallback_tag = Anti_rationalization.gate_to_string Fallback in
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
                | Anti_rationalization.Approve -> ac + 1, rc
                | Anti_rationalization.Reject _ -> ac, rc + 1
              in
              let gate = string_field json "gate" in
              let prev = Option.value ~default:0 (StringMap.find_opt gate gc) in
              let gc' = StringMap.add gate (prev + 1) gc in
              let vh' = StringMap.add hash v vh in
              let ev_cascade = string_field json "evaluator_cascade" in
              let gen_cascade = string_field json "generator_cascade" in
              let vwg', cmm' =
                if gen_cascade <> "" && ev_cascade <> "" then
                  vwg + 1,
                  (if not (String.equal gen_cascade ev_cascade) then cmm + 1 else cmm)
                else
                  vwg, cmm
              in
              let fbr' =
                if gate = fallback_tag && List.length fbr < max_fallback_reasons then
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
          else
            match ev, hv with
            | Anti_rationalization.Approve, Reject_label -> (fp + 1, fn, ag)
            | _ -> (fp, fn + 1, ag)
    ) verdict_hashes (0, 0, 0)
  in
  let labeled_total = false_pos + false_neg + agree in
  let agreement_rate =
    if labeled_total = 0 then 0.0
    else float_of_int agree /. float_of_int labeled_total
  in
  let gate_json = StringMap.bindings gate_counts |> List.map (fun (k, v) -> (k, `Int v)) in
  let fallback_count =
    Option.value ~default:0
      (StringMap.find_opt (Anti_rationalization.gate_to_string Fallback) gate_counts)
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
    ("verdicts_with_generator_cascade", `Int verdicts_with_generator);
    ("cross_model_match_count", `Int cross_model_match);
    ("cross_model_rate", `Float cross_model_rate);
    ("recent_fallback_reasons",
     `List (List.rev_map (fun s -> `String s) recent_fallback_reasons));
  ]
