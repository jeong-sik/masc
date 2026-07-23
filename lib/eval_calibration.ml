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
  | Task.Anti_rationalization.Approve -> "approve"
  | Task.Anti_rationalization.Reject "" -> "reject"
  | Task.Anti_rationalization.Reject reason -> "reject:" ^ reason

let verdict_of_string raw =
  match String.split_on_char ':' raw with
  | ["approve"] -> Some Task.Anti_rationalization.Approve
  | ["reject"] -> Some (Task.Anti_rationalization.Reject "")
  | "reject" :: reason_parts ->
      Some (Task.Anti_rationalization.Reject (String.concat ":" reason_parts))
  | _ -> None

let label_verdict_of_verdict = function
  | Task.Anti_rationalization.Approve -> Approve_label
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

(** Set the process-local verdict store to an explicit isolated directory.
    Offline eval tooling uses this after verdict-store isolation checks; tests
    use [set_store_for_testing] as a compatibility alias. *)
let set_store ~base_dir =
  store_ref := Some (Dated_jsonl.create ~base_dir ())

let set_store_for_testing = set_store

(** Resolve where an offline eval tool's [--record-verdicts] verdicts are
    written. Such a tool drives a real judge and persists verdicts; if those
    land in the live ledger ([base_path ()] = $MASC_BASE_PATH/data/verdicts)
    they contaminate production {!calibration_stats} and the dashboard (see
    docs/design/completion-trust-calibration-wiring.md D3). We therefore refuse
    a silent default to the live store (an "unknown -> permissive default" is the
    exact failure mode this guards against) and require an explicit isolated
    scratch path that is not the live store. [live_store_dir] is the caller's
    live verdict store ([None] when no live store exists), passed in so tests can
    supply a deterministic base path.

    - [record_verdicts = false] -> [Ok None] (nothing to record).
    - no [verdict_store_dir] -> [Error] (no silent fallback to the live store).
    - [verdict_store_dir] equal to or below [live_store_dir] -> [Error] (would
      pollute).
    - otherwise -> [Ok (Some dir)]. *)
(* Local by design: this guard needs absolute lexical cleanup that composes with
   existing-prefix realpath for paths that may not exist yet. Env/basepath
   normalizers deliberately carry broader policy such as HOME expansion. *)
let lexical_normalize_abs abs =
  let parts = String.split_on_char '/' abs in
  let stack = ref [] in
  List.iter
    (function
      | "" | "." -> ()
      | ".." ->
        (match !stack with
         | _ :: rest -> stack := rest
         | [] -> ())
      | part -> stack := part :: !stack)
    parts;
  "/" ^ String.concat "/" (List.rev !stack)
;;

let lexical_abs ?cwd raw =
  let abs =
    if Filename.is_relative raw then
      Filename.concat
        (match cwd with Some d -> d | None -> Config_dir_resolver.current_working_dir ())
        raw
    else
      raw
  in
  lexical_normalize_abs abs
;;

let rec realpath_existing_prefix abs =
  try Unix.realpath abs with
  | Unix.Unix_error _ | Invalid_argument _ | Sys_error _ ->
    let parent = Filename.dirname abs in
    if String.equal parent abs then abs
    else
      let parent_real = realpath_existing_prefix parent in
      lexical_normalize_abs (Filename.concat parent_real (Filename.basename abs))
;;

let normalize_for_store_collision ?cwd raw =
  raw |> lexical_abs ?cwd |> realpath_existing_prefix |> lexical_normalize_abs
;;

let absolute_workspace_base_path ?cwd raw =
  raw
  |> Env_config_core.normalize_masc_base_path_input
  |> normalize_for_store_collision ?cwd
;;

let same_or_child_path ~parent child =
  String.equal child parent
  || (not (String.equal parent "/")
      && String.length child > String.length parent
      && child.[String.length parent] = '/'
      && String.sub child 0 (String.length parent) = parent)
;;

let resolve_record_verdicts_store ?cwd ~record_verdicts ~verdict_store_dir
    ~(live_store_dir : string option) () : (string option, string) result =
  if not record_verdicts then Ok None
  else
    let is_live d =
      match live_store_dir with
      | Some l ->
        let candidate = normalize_for_store_collision ?cwd d in
        let live = normalize_for_store_collision ?cwd l in
        same_or_child_path ~parent:live candidate
      | None -> false
    in
    match verdict_store_dir with
    | None ->
      Error
        "--record-verdicts requires --verdict-store-dir DIR (an isolated scratch \
         path); refusing to write the live verdict store."
    | Some d when String.trim d = "" ->
      Error "--verdict-store-dir must not be empty."
    | Some d when is_live d ->
      Error
        (Printf.sprintf
           "--verdict-store-dir %s is inside the live verdict store; pick an \
            isolated scratch path so the eval does not contaminate production \
            calibration."
           d)
    | Some d -> Ok (Some d)
;;

let missing_cross_verifier_error =
  "--record-verdicts without --evaluator-runtime requires [runtime].cross_verifier \
   (routes.cross_verifier); configure it in runtime.toml or pass \
   --evaluator-runtime ID"
;;

let resolve_record_verdicts_evaluator ~record_verdicts ~generator_runtime
    ~evaluator_runtime ~cross_verifier_runtime : (string option, string) result =
  if not record_verdicts then Ok evaluator_runtime
  else
    match evaluator_runtime with
    | Some id ->
      let id = String.trim id in
      if id = "" then Error "--evaluator-runtime must not be empty"
      else Ok (Some id)
    | None -> (
      let generator_runtime = String.trim generator_runtime in
      match cross_verifier_runtime with
      | Some id ->
        let id = String.trim id in
        if id = "" then Error missing_cross_verifier_error
        else if String.equal id generator_runtime then
          Error
            (Printf.sprintf
               "--record-verdicts without --evaluator-runtime requires \
                [runtime].cross_verifier to be distinct from --runtime (%s); \
                pass --evaluator-runtime ID to make same-model evaluation \
                explicit."
               generator_runtime)
        else Ok None
      | None -> Error missing_cross_verifier_error)
;;

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
(* OAS Harness.verdict conversion (#3165)                            *)
(* ================================================================ *)

(** Convert a MASC [verdict_record] to an OAS [Harness.verdict].
    Maps "approve" → passed=true, "reject:*" → passed=false.
    The gate name is recorded as evidence for traceability. *)
let to_harness_verdict (r : verdict_record) : Agent_sdk.Harness.verdict =
  let passed =
    match r.verdict with
    | Task.Anti_rationalization.Approve -> true
    | Task.Anti_rationalization.Reject _ -> false
  in
  let score = if passed then Some 1.0 else Some 0.0 in
  let evidence = [
    Printf.sprintf "gate=%s" (Task.Anti_rationalization.gate_to_string r.gate);
    Printf.sprintf "evaluator=%s" r.evaluator_runtime;
    Printf.sprintf "task_id=%s" r.task_id;
  ] in
  let detail =
    if passed then
      None
    else
      Some
        (Printf.sprintf "rejected at %s gate: %s"
           (Task.Anti_rationalization.gate_to_string r.gate)
           (verdict_to_string r.verdict))
  in
  { Agent_sdk.Harness.passed; score; evidence; detail }

(* ================================================================ *)
(* Record writing                                                    *)
(* ================================================================ *)

let record_verdict
    ~(task_id : string)
    ~(req : Task.Anti_rationalization.review_request)
    ~(result : Task.Anti_rationalization.review_result)
    ?(on_harness_verdict : (Agent_sdk.Harness.verdict -> unit) option)
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
    Dated_jsonl.append (get_store ()) (verdict_record_to_json record);
    (match on_harness_verdict with
     | Some cb ->
       (try cb (to_harness_verdict record) with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Harness.warn
            "[eval_calibration] on_harness_verdict callback failed: %s"
            (Printexc.to_string exn))
     | None -> ())

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
    | Task.Anti_rationalization.Approve, Reject_label -> true
    | Task.Anti_rationalization.Approve, Approve_label -> false
    | Task.Anti_rationalization.Reject _, Reject_label -> false
    | Task.Anti_rationalization.Reject _, Approve_label -> false
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
                | Task.Anti_rationalization.Approve -> ac + 1, rc
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
          else
            match ev, hv with
            | Task.Anti_rationalization.Approve, Reject_label -> (fp + 1, fn, ag)
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
