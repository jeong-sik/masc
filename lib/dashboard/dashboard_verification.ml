(** Dashboard projection for verification requests.

    Reads [<base_path>/verifications/*.json] via {!Verification.list_requests}
    and emits the Mission detail table row structure. No mutation, no
    network. *)

module V = Verification

(* ── Constants ──────────────────────────────────────── *)

let default_limit = 100
let min_limit = 1
let max_limit = 500

(* ── Helpers ────────────────────────────────────────── *)

let clamp_limit limit =
  let l = match limit with
    | Some n -> n
    | None -> default_limit
  in
  if l < min_limit then min_limit
  else if l > max_limit then max_limit
  else l

let iso_of_unix = Dashboard_utils.iso_of_unix

(** Criteria carry the "completion_contract" in their Custom text.
    Non-Custom criteria (Contains, Schema_match, ...) are automated checks,
    not contract text, so we skip them here. *)
let completion_contract_of_criteria (criteria : V.criterion list) : string list =
  List.filter_map (function
    | V.Custom text -> Some text
    | V.Contains _ | V.Not_contains _ | V.Schema_match _ -> None
  ) criteria

(** The Verification_protocol.on_submit_for_verification writes
    [output = { evidence_refs = [...]; task_title = "..." }]. We read
    evidence_refs in a tolerant way: missing or malformed -> empty list. *)
let required_evidence_of_output (output : Yojson.Safe.t) : string list =
  match output with
  | `Assoc fields ->
      (match List.assoc_opt "evidence_refs" fields with
       | Some (`List items) ->
           List.filter_map (function
             | `String s -> Some s
             | _ -> None
           ) items
       | _ -> [])
  | _ -> []

(* Pull task_title from the submit envelope so the UI detail cell has a
   fallback when contract/evidence/verdict_reason are all empty. Empty
   string means "nothing to show"; the UI treats it identically to missing. *)
let task_title_of_output (output : Yojson.Safe.t) : string =
  match output with
  | `Assoc fields ->
      (match List.assoc_opt "task_title" fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

(** Status + verdict + approver triple. Keeps all three derivations in one
    place so the match is exhaustive over the Verification state machine. *)
let derive_status_fields (req : V.verification_request)
  : string * string option * string * string option =
  (* returns (status, verdict_opt, verdict_reason, approved_by_opt) *)
  match req.status with
  | V.Pending ->
      "pending", None, "", None
  | V.Assigned _ ->
      "pending", None, "", None
  | V.Completed V.Pass ->
      "approved", Some "pass", "", req.verifier
  | V.Completed (V.Fail reason) ->
      "rejected", Some "fail", reason, req.verifier
  | V.Completed (V.Partial (_, reason)) ->
      "rejected", Some "partial", reason, req.verifier

(** Per-request JSON row. *)
let request_to_json (req : V.verification_request) : Yojson.Safe.t =
  let status, verdict_opt, verdict_reason, approved_by =
    derive_status_fields req
  in
  let contract = completion_contract_of_criteria req.criteria in
  let evidence = required_evidence_of_output req.output in
  let task_title = task_title_of_output req.output in
  `Assoc [
    ("request_id", `String req.id);
    ("task_id", `String req.task_id);
    ("task_title", `String task_title);
    (* Keeper name: file-based storage has no dedicated keeper field,
       but the verifier is a keeper when assigned. Surface None when
       unassigned rather than inventing a value. *)
    ("keeper",
     match req.verifier with
     | Some v -> `String v
     | None -> `Null);
    ("status", `String status);
    ("created_at", `String (iso_of_unix req.created_at));
    ("submitted_by", `String req.worker);
    ("approved_by",
     match approved_by with
     | Some v -> `String v
     | None -> `Null);
    ("completion_contract",
     `List (List.map (fun s -> `String s) contract));
    ("required_evidence",
     `List (List.map (fun s -> `String s) evidence));
    ("verdict",
     match verdict_opt with
     | Some v -> `String v
     | None -> `Null);
    ("verdict_reason", `String verdict_reason);
  ]

(* ── Snapshot assembly ──────────────────────────────── *)

(** Load the raw verification request list from the current MASC base_path.

    Protected against missing base_path or filesystem errors — failures
    surface as an empty list plus a log line, matching the tolerance
    [Verification.list_requests] already offers on a missing dir. *)
let load_requests () : V.verification_request list =
  let base_path = Env_config_core.base_path () in
  try V.list_requests base_path
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Task.warn "[dashboard-verification] list_requests failed: %s"
        (Printexc.to_string exn);
      []

(** Filter by task_id when the caller requested a specific task. Empty
    string is treated as "no filter" to match the HTTP contract. *)
let filter_by_task_id (requests : V.verification_request list)
    (task_id : string option) : V.verification_request list =
  match task_id with
  | None -> requests
  | Some "" -> requests
  | Some id ->
      List.filter (fun (r : V.verification_request) ->
        String.equal r.V.task_id id) requests

let sort_desc (requests : V.verification_request list)
  : V.verification_request list =
  List.sort (fun (a : V.verification_request) b ->
    compare b.V.created_at a.V.created_at) requests

let take n lst =
  let rec aux acc n = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> aux (x :: acc) (n - 1) rest
  in
  aux [] n lst

let now_iso () = Types.now_iso ()

let requests_json ?task_id ?limit () : Yojson.Safe.t =
  let limit = clamp_limit limit in
  let all = load_requests () in
  let filtered = filter_by_task_id all task_id in
  let sorted = sort_desc filtered in
  let trimmed = take limit sorted in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("total", `Int (List.length filtered));
    ("requests", `List (List.map request_to_json trimmed));
  ]
