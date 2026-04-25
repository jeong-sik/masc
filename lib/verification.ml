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
           (match List.assoc_opt "value" fields with
            | Some (`String s) -> Ok (Contains s)
            | _ -> Error "contains requires 'value' string field")
       | Some (`String "not_contains") ->
           (match List.assoc_opt "value" fields with
            | Some (`String s) -> Ok (Not_contains s)
            | _ -> Error "not_contains requires 'value' string field")
       | Some (`String "custom") ->
           (match List.assoc_opt "description" fields with
            | Some (`String s) -> Ok (Custom s)
            | _ -> Error "custom requires 'description' string field")
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
       | _ -> Error "unknown or missing verdict")
  | _ -> Error "verdict must be a JSON object"

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
            | _ -> Error "assigned requires 'verifier' field")
       | Some (`String "completed") ->
           (match verdict_of_yojson (`Assoc fields) with
            | Ok v -> Ok (Completed v)
            | Error e -> Error e)
       | _ -> Error "unknown request status")
  | _ -> Error "request status must be a JSON object"

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
                     Eio.traceln "[Verification] dropping invalid criterion: %s" msg;
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
                   Eio.traceln "[Verification] unparseable status, falling back to Pending: %s" msg;
                   Pending)
             | None -> Pending
           in
           Ok { id; task_id; output; criteria; worker; verifier; created_at; status }
       | _ -> Error "verification request requires 'id', 'task_id', 'worker' fields")
  | _ -> Error "verification request must be a JSON object"

(** ID generation — cryptographic random, 128-bit space.

    Prior implementation (#7544) combined [Time_compat.now ()] with
    [Hashtbl.hash (Unix.gettimeofday ())], which collided inside the
    same millisecond. Now shared with [Coord_task]'s verification_id
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
      let fails = List.filter (function Fail _ -> true | _ -> false) results in
      let partials = List.filter (function Partial _ -> true | _ -> false) results in
      if fails <> [] then
        let reasons = List.filter_map (function
          | Fail r -> Some r
          | _ -> None
        ) fails in
        Fail (String.concat "; " reasons)
      else if partials <> [] then
        let scores = List.filter_map (function
          | Partial (s, _) -> Some s
          | _ -> None
        ) partials in
        let avg = List.fold_left (+.) 0.0 scores /. Float.of_int (List.length scores) in
        let reasons = List.filter_map (function
          | Partial (_, r) -> Some r
          | _ -> None
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

let verifications_dir = Coord_verification_store.verifications_dir

let ensure_dir path =
  Fs_compat.mkdir_p path

let request_path base_path req_id =
  Coord_verification_store.request_path base_path req_id

let save_request base_path req =
  try
    let dir = verifications_dir base_path in
    ensure_dir dir;
    let json = request_to_yojson req in
    let path = request_path base_path req.id in
    match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
    | Ok () -> Ok req.id
    | Error e -> Error e
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf
           "save_request %s: %s"
           req.id
           (Printexc.to_string exn))

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

let list_requests base_path =
  let surface = "verification" in
  let observe_drop ~reason =
    Prometheus.inc_counter Prometheus.metric_persistence_read_drops
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
  if not (Sys.file_exists dir) then
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
  match save_request base_path req with
  | Ok _ -> Ok req
  | Error e -> Error e

let assign_verifier ~base_path ~req_id ~verifier =
  match load_request base_path req_id with
  | Error e -> Error e
  | Ok req ->
      match validate_cross_agent ~worker:req.worker ~verifier with
      | Error e -> Error e
      | Ok () ->
          let updated = { req with status = Assigned verifier; verifier = Some verifier } in
          match save_request base_path updated with
          | Ok _ -> Ok updated
          | Error e -> Error e

let submit_verdict ~base_path ~req_id ~verifier ~verdict =
  match load_request base_path req_id with
  | Error e -> Error e
  | Ok req ->
      match validate_cross_agent ~worker:req.worker ~verifier with
      | Error e -> Error e
      | Ok () ->
          (* Persist the verifier into the record, not just validate it.
             Before this fix callers that skipped [assign_verifier] left
             [req.verifier = None] forever, which surfaced as "approved
             without approver" in the dashboard projection. *)
          let updated =
            { req with status = Completed verdict; verifier = Some verifier }
          in
          match save_request base_path updated with
          | Ok _ -> Ok updated
          | Error e -> Error e

(* Sentinel verifier recorded when auto_verify transitions a request to
   Completed without a human/LLM judge. Keeps approved_by non-null in the
   dashboard projection so operators can distinguish rule-based passes
   from peer-agent verdicts ("operator:*") and peer keepers (bare names). *)
let auto_verifier_sentinel = "auto"

let auto_verify ~base_path ~req_id =
  match load_request base_path req_id with
  | Error e -> Error e
  | Ok req ->
      let has_custom = List.exists (function Custom _ -> true | _ -> false) req.criteria in
      if has_custom then
        Error "Cannot auto-verify: custom criteria require agent judgment"
      else
        let verdict = evaluate_all req.output req.criteria in
        let verifier =
          match req.verifier with
          | Some _ as v -> v
          | None -> Some auto_verifier_sentinel
        in
        let updated = { req with status = Completed verdict; verifier } in
        match save_request base_path updated with
        | Ok _ -> Ok updated
        | Error e -> Error e

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
    ("verifier", (match req.verifier with
                  | Some v -> `String v
                  | None -> `Null));
    ("criteria_counts", criteria_counts req.criteria);
  ]

let attribution_of_request (req : verification_request) : Attribution.t option =
  match req.status with
  | Pending | Assigned _ -> None
  | Completed verdict ->
    let origin = origin_of_criteria req.criteria in
    let evidence = evidence_of_request req in
    Some (to_attribution ~origin ~evidence verdict)
