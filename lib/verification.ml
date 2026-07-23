(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories in multi-agent
    systems. Independent verification ensures Worker Agent ≠ Verifier Agent.

    Design:
    - File-based storage under .masc/verifications/
    - Criteria-based checking (schema, contains, custom)
    - Cross-agent enforcement (worker cannot verify own output)
    - Integration with existing task lifecycle
*)

open Result.Syntax

(** Verification criteria *)
type criterion =
  | Schema_match of Yojson.Safe.t   (** Output matches JSON schema *)
  | Contains of string              (** Output must contain string *)
  | Not_contains of string          (** Output must not contain string *)
  | Custom of string                (** Natural language criterion for verifier *)
[@@deriving show, eq]

let criterion_to_yojson = function
  | Schema_match schema ->
      `Assoc [("type", `String "schema_match"); ("schema", schema)]
  | Contains s ->
      `Assoc [("type", `String "contains"); ("value", `String s)]
  | Not_contains s ->
      `Assoc [("type", `String "not_contains"); ("value", `String s)]
  | Custom s ->
      `Assoc [("type", `String "custom"); ("description", `String s)]

let criterion_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "type" fields with
       | Some (`String "schema_match") ->
           (match List.assoc_opt "schema" fields with
            | Some schema -> Ok (Schema_match schema)
            | None -> Error "schema_match requires 'schema' field")
       | Some (`String "contains") ->
           let* value =
             match List.assoc_opt "value" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "contains requires 'value' string field"
           in
           Ok (Contains value)
       | Some (`String "not_contains") ->
           let* value =
             match List.assoc_opt "value" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "not_contains requires 'value' string field"
           in
           Ok (Not_contains value)
       | Some (`String "custom") ->
           let* description =
             match List.assoc_opt "description" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "custom requires 'description' string field"
           in
           Ok (Custom description)
       | Some (`String t) -> Error (Printf.sprintf "unknown criterion type: %s" t)
       | _ -> Error "criterion requires 'type' field")
  | _ -> Error "criterion must be a JSON object"

(** Verification verdict *)
type verdict =
  | Pass
  | Fail of string
  | Partial of float * string  (** score (0.0-1.0), reason *)
[@@deriving show, eq]

let verdict_to_yojson = function
  | Pass -> `Assoc [("verdict", `String "pass")]
  | Fail reason -> `Assoc [("verdict", `String "fail"); ("reason", `String reason)]
  | Partial (score, reason) ->
      `Assoc [
        ("verdict", `String "partial");
        ("score", `Float score);
        ("reason", `String reason);
      ]

let verdict_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "verdict" fields with
       | Some (`String "pass") -> Ok Pass
       | Some (`String "fail") ->
           let reason = match List.assoc_opt "reason" fields with
             | Some (`String s) -> s
             | _ -> "no reason given"
           in
           Ok (Fail reason)
       | Some (`String "partial") ->
           let score = match List.assoc_opt "score" fields with
             | Some (`Float f) -> f
             | Some (`Int n) -> Float.of_int n
             | _ -> 0.0
           in
           let reason = match List.assoc_opt "reason" fields with
             | Some (`String s) -> s
             | _ -> "no reason given"
           in
           Ok (Partial (score, reason))
       | other ->
           let got =
             match other with
             | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
             | None -> "field missing"
           in
           Error
             (Printf.sprintf
                "unknown or missing 'verdict' (expected one of: \
                 pass | fail | partial; %s)"
                got))
  | other ->
      Error
        (Printf.sprintf
           "verdict must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

(** Verification request *)
type verification_request = {
  id: string;
  task_id: string;
  output: Yojson.Safe.t;
  criteria: criterion list;
  worker: string;           (** Agent who produced the output *)
  verifier: string option;  (** Specific verifier, or None for any *)
  created_at: float;
  status: request_status;
}

and request_status =
  | Pending
  | Assigned of string    (** Verifier agent name *)
  | Completed of verdict
[@@deriving show]

(** Serialization *)

let request_status_to_yojson = function
  | Pending -> `Assoc [("status", `String "pending")]
  | Assigned agent ->
      `Assoc [("status", `String "assigned"); ("verifier", `String agent)]
  | Completed v ->
      let base = verdict_to_yojson v in
      (match base with
       | `Assoc fields -> `Assoc (("status", `String "completed") :: fields)
       | _ -> `Assoc [("status", `String "completed")])

let request_status_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String "pending") -> Ok Pending
       | Some (`String "assigned") ->
           (match List.assoc_opt "verifier" fields with
            | Some (`String a) -> Ok (Assigned a)
            | other ->
                let got =
                  match other with
                  | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
                  | None -> "field missing"
                in
                Error
                  (Printf.sprintf
                     "assigned status requires 'verifier' string field \
                      (%s)"
                     got))
       | Some (`String "completed") ->
           let* v = verdict_of_yojson (`Assoc fields) in
           Ok (Completed v)
       | other ->
           let got =
             match other with
             | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
             | None -> "field missing"
           in
           Error
             (Printf.sprintf
                "unknown 'status' (expected one of: pending | assigned \
                 | completed; %s)"
                got))
  | other ->
      Error
        (Printf.sprintf
           "request status must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

let request_to_yojson req =
  `Assoc [
    ("id", `String req.id);
    ("task_id", `String req.task_id);
    ("output", req.output);
    ("criteria", `List (List.map criterion_to_yojson req.criteria));
    ("worker", `String req.worker);
    ("verifier", Json_util.string_opt_to_json req.verifier);
    ("created_at", `Float req.created_at);
    ("status", request_status_to_yojson req.status);
  ]

let request_of_yojson = function
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let get_float key =
        match List.assoc_opt key fields with
        | Some (`Float f) -> Some f
        | Some (`Int n) -> Some (Float.of_int n)
        | _ -> None
      in
      (match get_string "id", get_string "task_id", get_string "worker" with
       | Some id, Some task_id, Some worker ->
           let output = match List.assoc_opt "output" fields with
             | Some j -> j
             | None -> `Null
           in
           let criteria = match List.assoc_opt "criteria" fields with
             | Some (`List l) ->
                 List.filter_map (fun j ->
                   match criterion_of_yojson j with
                   | Ok c -> Some c
                   | Error msg ->
                     Log.Misc.warn "[Verification] dropping invalid criterion: %s" msg;
                     None
                 ) l
             | _ -> []
           in
           let verifier = match List.assoc_opt "verifier" fields with
             | Some (`String s) -> Some s
             | _ -> None
           in
           let created_at = match get_float "created_at" with
             | Some f -> f
             | None -> Time_compat.now ()
           in
           let status = match List.assoc_opt "status" fields with
             | Some json -> (match request_status_of_yojson json with
                 | Ok s -> s
                 | Error msg ->
                   Log.Misc.warn "[Verification] unparseable status, falling back to Pending: %s" msg;
                   Pending)
             | None -> Pending
           in
           Ok { id; task_id; output; criteria; worker; verifier; created_at; status }
       | id_opt, task_opt, worker_opt ->
           let missing =
             List.filter_map
               (fun (name, opt) -> if Option.is_none opt then Some name else None)
               [ "id", id_opt; "task_id", task_opt; "worker", worker_opt ]
           in
           Error
             (Printf.sprintf
                "verification request missing required string field(s) \
                 [%s] (object had keys: [%s])"
                (String.concat ", " missing)
                (String.concat ", " (List.map fst fields))))
  | other ->
      Error
        (Printf.sprintf
           "verification request must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

let request_status_is_actionable = function
  | Pending | Assigned _ -> true
  | Completed _ -> false

let request_is_actionable (req : verification_request) =
  request_status_is_actionable req.status

(** ID generation — cryptographic random, 128-bit space.

    Prior implementation (#7544) combined [Time_compat.now ()] with
    [Hashtbl.hash (Unix.gettimeofday ())], which collided inside the
    same millisecond. Now shared with [Workspace_task]'s verification_id
    generation via [Random_id], so the algorithm is defined once. *)
let generate_id () =
  Random_id.prefixed ~prefix:"vrf-" ~bytes:16

(* Byte-wise non-empty literal substring containment.

   [Contains]/[Not_contains] criteria interpolate user-supplied needles,
   so [Re.compile] cannot be hoisted.  But these are pure substring
   checks with no regex semantics: every criterion evaluation
   previously paid a fresh DFA build before [execp] could run.  Replace
   with a bounded scan and keep the empty-needle contract local to this
   helper: [Contains ""] must fail and [Not_contains ""] must pass. *)
let contains_nonempty_literal ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 || nlen > hlen then false
  else
    let rec match_at i j =
      if j = nlen then true
      else if String.get haystack (i + j) <> String.get needle j then false
      else match_at i (j + 1)
    in
    let last = hlen - nlen in
    let rec loop i =
      if i > last then false
      else if match_at i 0 then true
      else loop (i + 1)
    in
    loop 0

(** Automated criterion evaluation *)
let evaluate_criterion output criterion =
  let output_str = Yojson.Safe.to_string output in
  match criterion with
  | Schema_match _schema ->
      (match output with
       | `Null -> Fail "output is null"
       | _ -> Pass)
  | Contains needle ->
      if contains_nonempty_literal ~needle output_str
      then Pass
      else Fail (Printf.sprintf "output does not contain '%s'" needle)
  | Not_contains needle ->
      if contains_nonempty_literal ~needle output_str
      then Fail (Printf.sprintf "output contains forbidden '%s'" needle)
      else Pass
  | Custom _ ->
      Partial (0.5, "custom criterion requires verifier judgment")

(** Evaluate all criteria, return aggregate verdict *)
let evaluate_all output criteria =
  match criteria with
  | [] -> Pass  (* No criteria = auto-pass *)
  | _ ->
      let results = List.map (evaluate_criterion output) criteria in
      let fails = List.filter (function Fail _ -> true | Pass | Partial _ -> false) results in
      let partials = List.filter (function Partial _ -> true | Pass | Fail _ -> false) results in
      if fails <> [] then
        (* [fails] was filtered to [Fail _] only; [Pass]/[Partial] are dead. *)
        let reasons = List.filter_map (function
          | Fail r -> Some r
          | Pass | Partial _ -> None
        ) fails in
        Fail (String.concat "; " reasons)
      else if partials <> [] then
        (* [partials] was filtered to [Partial _] only; [Pass]/[Fail] are dead. *)
        let scores = List.filter_map (function
          | Partial (s, _) -> Some s
          | Pass | Fail _ -> None
        ) partials in
        let avg = List.fold_left (+.) 0.0 scores /. Float.of_int (List.length scores) in
        let reasons = List.filter_map (function
          | Partial (_, r) -> Some r
          | Pass | Fail _ -> None
        ) partials in
        Partial (avg, String.concat "; " reasons)
      else
        Pass

(** Cross-agent enforcement: verifier must differ from worker *)
let validate_cross_agent ~worker ~verifier =
  if String.equal worker verifier then
    Error "Cross-agent violation: worker cannot verify own output"
  else
    Ok ()

(** File-based storage *)

let verifications_dir = Workspace_verification_store.verifications_dir

let request_path base_path req_id =
  Workspace_verification_store.request_path base_path req_id

(* [list_requests] used to walk [verifications/*.json] on every dashboard
   refresh: one [Safe_ops.list_dir_safe] for the directory followed by
   [Safe_ops.read_json_eio] per file (the per-file [load_request] in the
   filter_map below).  Dashboard layers — [Dashboard_verification.proof_compose],
   [summary_json], [requests_json] — and verification HTTP routes all funnel
   into this scan.  PR #19015 collapsed two scans into one within the proof
   compose, but each cache miss still pays N+1 disk reads.

   This storage-level cache keeps the most-recent parsed list addressed by
   [(base_path, dir mtime)].  When the directory has not changed since the
   last scan, the cache returns the previously-parsed list — a single
   [Unix.stat] syscall — and skips the readdir + per-file open chain.

   Single-entry [Atomic.t] is sufficient because production deployments run
   a single [base_path] per MASC server instance.  Multi-tenant workloads
   would alternate cache misses but never serve stale data — the mtime guard
   detects directory churn from any source (file create/update/delete all
   bump [st_mtime]).  Write paths below ([save_request]) additionally
   invalidate the cache explicitly to close the sub-second mtime resolution
   race on fast filesystems. *)
type list_requests_cache_entry = {
  cache_base_path : string;
  dir_mtime : float;
  results : verification_request list;
}

let list_requests_cache : list_requests_cache_entry option Atomic.t =
  Atomic.make None

let invalidate_list_requests_cache () =
  Atomic.set list_requests_cache None

let dir_mtime_opt dir =
  try Some (Unix.stat dir).Unix.st_mtime with
  | Unix.Unix_error _ | Sys_error _ -> None

let save_request base_path req =
  try
    let dir = verifications_dir base_path in
    Fs_compat.mkdir_p dir;
    let json = request_to_yojson req in
    let path = request_path base_path req.id in
    let* () = Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) in
    invalidate_list_requests_cache ();
    Ok req.id
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf
           "save_request %s: %s"
           req.id
           (Printexc.to_string exn))

(* RFC-0221 §3.1: compensation for atomic submit. Remove a verification record
   when the status commit it was written for did not land, so the record store
   and [task_status] are never left disagreeing. A missing file is success
   (idempotent), so the caller can compensate without first checking existence. *)
let delete_request base_path req_id =
  try
    let path = request_path base_path req_id in
    if Sys.file_exists path then Sys.remove path;
    invalidate_list_requests_cache ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf "delete_request %s: %s" req_id (Printexc.to_string exn))

let load_request base_path req_id =
  let path = request_path base_path req_id in
  if Sys.file_exists path then
    try
      let json = Safe_ops.read_json_eio path in
      request_of_yojson json
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Error (Printf.sprintf "Failed to load verification %s: %s" req_id (Printexc.to_string exn))
  else
    Error (Printf.sprintf "Verification %s not found" req_id)

let list_requests_uncached base_path =
  let surface = "verification" in
  let observe_drop ~reason =
    Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
      ~labels:[("surface", surface); ("reason", reason)] ()
  in
  let report_drop ~reason ~path ~detail =
    Safe_ops.report_persistence_read_drop
      ~on_drop:(fun () -> observe_drop ~reason)
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = verifications_dir base_path in
  let dir_exists =
    try Sys.file_exists dir with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Keeper_fd_pressure.note_exception ~site:"verification.list_requests.exists" exn;
      report_drop
        ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error
        ~path:dir
        ~detail:(Printexc.to_string exn);
      false
  in
  if not dir_exists then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
      report_drop ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error ~path:dir ~detail;
      []
    | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
          let id = Filename.chop_suffix f ".json" in
          Safe_ops.result_to_option_logged
            ~on_drop:(fun () ->
              observe_drop ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error)
            ~surface
            ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
            ~path:(Filename.concat dir f)
            (load_request base_path id))

(* Public entry: check the mtime-keyed cache before the readdir + N+1 open
   chain.  A cache hit returns the previously-parsed list after a single
   [Unix.stat] syscall; cache miss falls through to [list_requests_uncached]
   and refreshes the entry.  See [list_requests_cache] above for the design. *)
let list_requests base_path =
  let dir = verifications_dir base_path in
  match dir_mtime_opt dir with
  | None ->
      (* Directory missing or stat failed — defer to the uncached path so
         the existing directory check and explicit error reporting run. *)
      list_requests_uncached base_path
  | Some mtime -> (
      match Atomic.get list_requests_cache with
      | Some entry
        when String.equal entry.cache_base_path base_path
             && Float.equal entry.dir_mtime mtime ->
          entry.results
      | _ ->
          let results = list_requests_uncached base_path in
          Atomic.set list_requests_cache
            (Some { cache_base_path = base_path; dir_mtime = mtime; results });
          results)

(** High-level API *)

let create_request ~base_path ~task_id ~output ~criteria ~worker ?verifier ?request_id () =
  let id = match request_id with Some rid -> rid | None -> generate_id () in
  let req = {
    id;
    task_id;
    output;
    criteria;
    worker;
    verifier;
    created_at = Time_compat.now ();
    status = Pending;
  } in
  let* _req_id = save_request base_path req in
  Ok req

let assign_verifier ~base_path ~req_id ~verifier =
  let* req = load_request base_path req_id in
  let* () = validate_cross_agent ~worker:req.worker ~verifier in
  let updated = { req with status = Assigned verifier; verifier = Some verifier } in
  let* _req_id = save_request base_path updated in
  Ok updated

let submit_verdict ~base_path ~req_id ~verifier ~verdict =
  let* req = load_request base_path req_id in
  let* () = validate_cross_agent ~worker:req.worker ~verifier in
  (* Persist the verifier into the record, not just validate it.
     Before this fix callers that skipped [assign_verifier] left
     [req.verifier = None] forever, which surfaced as "approved
     without approver" in the dashboard projection. *)
  let updated =
    { req with status = Completed verdict; verifier = Some verifier }
  in
  let* _req_id = save_request base_path updated in
  Ok updated

(* Marker verifier recorded when auto_verify transitions a request to
   Completed without a human/LLM judge. Keeps approved_by non-null in the
   dashboard projection so operators can distinguish rule-based passes
   from peer-agent verdicts ("operator:*") and peer keepers (bare names). *)
let auto_verifier_marker = "auto"

let auto_verify ~base_path ~req_id =
  let* req = load_request base_path req_id in
  let has_custom = List.exists (function Custom _ -> true | Schema_match _ | Contains _ | Not_contains _ -> false) req.criteria in
  if has_custom then
    Error "Cannot auto-verify: custom criteria require agent judgment"
  else
    let verdict = evaluate_all req.output req.criteria in
    let verifier =
      match req.verifier with
      | Some _ as v -> v
      | None -> Some auto_verifier_marker
    in
    let updated = { req with status = Completed verdict; verifier } in
    let* _req_id = save_request base_path updated in
    Ok updated

let pending_for_agent ~base_path ~agent =
  list_requests base_path
  |> List.filter (fun req ->
      match req.status with
      | Pending ->
          (match req.verifier with
           | Some v -> String.equal v agent
           | None -> not (String.equal req.worker agent))
      | Assigned v -> String.equal v agent
      | Completed _ -> false)

(* --- Attribution envelope conversion (Layer 1) ---
   Verification is hybrid: Schema_match / Contains / Not_contains are Det
   (rule-based), Custom is NonDet (LLM judge). Origin is derived from
   criteria. *)

let is_custom_criterion = function
  | Custom _ -> true
  | Schema_match _ | Contains _ | Not_contains _ -> false

let origin_of_criteria (criteria : criterion list) : Attribution.origin =
  if List.exists is_custom_criterion criteria then NonDet else Det

(* Count criteria by kind — keeps evidence compact while signalling the
   Det/NonDet mix behind the verdict. *)
let criteria_counts (criteria : criterion list) : Yojson.Safe.t =
  let schema = ref 0 and contains = ref 0 and not_contains = ref 0 and custom = ref 0 in
  List.iter (function
    | Schema_match _ -> incr schema
    | Contains _ -> incr contains
    | Not_contains _ -> incr not_contains
    | Custom _ -> incr custom
  ) criteria;
  `Assoc [
    ("schema_match", `Int !schema);
    ("contains", `Int !contains);
    ("not_contains", `Int !not_contains);
    ("custom", `Int !custom);
  ]

let to_attribution ~origin ~evidence (v : verdict) : Attribution.t =
  match v with
  | Pass ->
    Attribution.passed ~origin ~gate:"verification" ~evidence
  | Fail reason ->
    Attribution.policy_failed ~origin ~gate:"verification" ~evidence ~reason
  | Partial (score, rationale) ->
    Attribution.partial_pass ~origin ~gate:"verification" ~evidence
      ~score ~rationale

let evidence_of_request (req : verification_request) : Yojson.Safe.t =
  `Assoc [
    ("request_id", `String req.id);
    ("task_id", `String req.task_id);
    ("worker", `String req.worker);
    ("verifier", Json_util.string_opt_to_json req.verifier);
    ("criteria_counts", criteria_counts req.criteria);
  ]

let attribution_of_request (req : verification_request) : Attribution.t option =
  match req.status with
  | Pending | Assigned _ -> None
  | Completed verdict ->
    let origin = origin_of_criteria req.criteria in
    let evidence = evidence_of_request req in
    Some (to_attribution ~origin ~evidence verdict)
