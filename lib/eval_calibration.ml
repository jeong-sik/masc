(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists every anti-rationalization verdict to a date-partitioned JSONL
    store ([data/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label
    attachment for ground-truth tracking and divergence analysis to
    generate few-shot calibration examples for prompt improvement.

    @since #3068 — Harness Design evaluator calibration loop *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type verdict_record = {
  record_type : string;           (** "verdict" *)
  notes_hash : string;            (** SHA256(task_title ^ "\n" ^ completion_notes) *)
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : string;               (** "approve" | "reject:<reason>" *)
  gate : string;                  (** Anti_rationalization.gate_to_string output *)
  evaluator_cascade : string;
  generator_cascade : string option;
  fallback_reason : string option; (** Error message when gate="fallback" *)
  timestamp : float;
}

type label_record = {
  record_type : string;           (** "label" *)
  notes_hash : string;
  human_verdict : string;         (** "approve" | "reject" *)
  labeler : string;
  reason : string;
  timestamp : float;
}

type divergence = {
  notes_hash : string;
  evaluator_verdict : string;
  human_verdict : string;
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
  let me =
    match Env_config_core.me_root_opt () with
    | Some p -> p
    | None -> (Option.value ~default:"/tmp" (Env_config_core.home_dir_opt ())) ^ "/me"
  in
  Filename.concat me "data/verdicts"

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
    ("record_type", `String r.record_type);
    ("notes_hash", `String r.notes_hash);
    ("task_id", `String r.task_id);
    ("task_title", `String r.task_title);
    ("agent_name", `String r.agent_name);
    ("verdict", `String r.verdict);
    ("gate", `String r.gate);
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
    ("record_type", `String r.record_type);
    ("notes_hash", `String r.notes_hash);
    ("human_verdict", `String r.human_verdict);
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
  let passed = r.verdict = "approve" in
  let score = if passed then Some 1.0 else Some 0.0 in
  let evidence = [
    Printf.sprintf "gate=%s" r.gate;
    Printf.sprintf "evaluator=%s" r.evaluator_cascade;
    Printf.sprintf "task_id=%s" r.task_id;
  ] in
  let detail = if passed then None
    else Some (Printf.sprintf "rejected at %s gate: %s" r.gate r.verdict)
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
  let verdict_str = match result.verdict with
    | Anti_rationalization.Approve -> "approve"
    | Anti_rationalization.Reject reason -> "reject:" ^ reason
  in
  let record = {
    record_type = "verdict";
    notes_hash = hash;
    task_id;
    task_title = req.task_title;
    agent_name = req.agent_name;
    verdict = verdict_str;
    gate = Anti_rationalization.gate_to_string result.gate;
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
    ~(human_verdict : string)
    ~(labeler : string)
    ~(reason : string) : unit =
  let record = {
    record_type = "label";
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
  let verdicts = Hashtbl.create 64 in
  let labels = Hashtbl.create 64 in
  List.iter (fun json ->
    let rt = string_field json "record_type" in
    let hash = string_field json "notes_hash" in
    if rt = "verdict" then
      Hashtbl.replace verdicts hash json
    else if rt = "label" then
      Hashtbl.replace labels hash json
  ) records;
  (* Find disagreements *)
  let divergences = ref [] in
  Hashtbl.iter (fun hash v_json ->
    match Hashtbl.find_opt labels hash with
    | None -> ()
    | Some l_json ->
      let ev = string_field v_json "verdict" in
      let hv = string_field l_json "human_verdict" in
      let ev_norm = if ev = "reject" ||
                       (String.length ev >= 7 &&
                        String.sub ev 0 7 = "reject:") then "reject"
                    else ev in
      if ev_norm <> hv then
        divergences := {
          notes_hash = hash;
          evaluator_verdict = ev;
          human_verdict = hv;
          gate = string_field v_json "gate";
          task_title = string_field v_json "task_title";
        } :: !divergences
  ) verdicts;
  !divergences

(* ================================================================ *)
(* Few-shot example selection                                        *)
(* ================================================================ *)

let select_examples ~(max_examples : int) : calibration_example list =
  let divs = find_divergences () in
  (* Prioritize false positives: evaluator approved but human rejected *)
  let false_positives, others = List.partition (fun d ->
    d.evaluator_verdict = "approve" && d.human_verdict = "reject"
  ) divs in
  let sorted = false_positives @ others in
  let limited =
    if List.length sorted <= max_examples then sorted
    else List.filteri (fun i _ -> i < max_examples) sorted
  in
  List.map (fun d ->
    let correct = if d.human_verdict = "approve" then "APPROVE"
      else "REJECT: evaluator incorrectly approved" in
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
  let total_verdicts = ref 0 in
  let approve_count = ref 0 in
  let reject_count = ref 0 in
  let gate_counts : (string, int) Hashtbl.t = Hashtbl.create 8 in
  let labeled_hashes : (string, string) Hashtbl.t = Hashtbl.create 64 in
  let verdict_hashes : (string, string) Hashtbl.t = Hashtbl.create 64 in
  let recent_fallback_reasons : string list ref = ref [] in
  let max_fallback_reasons = 5 in
  let fallback_tag = Anti_rationalization.gate_to_string Fallback in
  List.iter (fun json ->
    let rt = string_field json "record_type" in
    let hash = string_field json "notes_hash" in
    if rt = "verdict" then begin
      incr total_verdicts;
      let v = string_field json "verdict" in
      if v = "approve" then incr approve_count
      else incr reject_count;
      let gate = string_field json "gate" in
      let prev = Option.value ~default:0 (Hashtbl.find_opt gate_counts gate) in
      Hashtbl.replace gate_counts gate (prev + 1);
      Hashtbl.replace verdict_hashes hash v;
      if gate = fallback_tag && List.length !recent_fallback_reasons < max_fallback_reasons then
        (let reason = string_field json "fallback_reason" in
         if reason <> "" then
           recent_fallback_reasons := reason :: !recent_fallback_reasons)
    end else if rt = "label" then
      Hashtbl.replace labeled_hashes hash (string_field json "human_verdict")
  ) records;
  (* Count divergences *)
  let false_pos = ref 0 in
  let false_neg = ref 0 in
  let agree = ref 0 in
  Hashtbl.iter (fun hash ev ->
    match Hashtbl.find_opt labeled_hashes hash with
    | None -> ()
    | Some hv ->
      let ev_norm = if ev = "reject" ||
                       (String.length ev >= 7 &&
                        String.sub ev 0 7 = "reject:") then "reject"
                    else ev in
      if ev_norm = hv then incr agree
      else if ev_norm = "approve" && hv = "reject" then incr false_pos
      else incr false_neg
  ) verdict_hashes;
  let labeled_total = !false_pos + !false_neg + !agree in
  let agreement_rate =
    if labeled_total = 0 then 0.0
    else float_of_int !agree /. float_of_int labeled_total
  in
  let gate_json = Hashtbl.fold (fun k v acc ->
    (k, `Int v) :: acc) gate_counts [] in
  let fallback_count =
    Option.value ~default:0
      (Hashtbl.find_opt gate_counts (Anti_rationalization.gate_to_string Fallback))
  in
  `Assoc [
    ("total_verdicts", `Int !total_verdicts);
    ("approve_count", `Int !approve_count);
    ("reject_count", `Int !reject_count);
    ("gate_distribution", `Assoc gate_json);
    ("labeled_count", `Int labeled_total);
    ("false_positive_count", `Int !false_pos);
    ("false_negative_count", `Int !false_neg);
    ("agreement_rate", `Float agreement_rate);
    ("fallback_count", `Int fallback_count);
    ("recent_fallback_reasons",
     `List (List.rev_map (fun s -> `String s) !recent_fallback_reasons));
  ]
