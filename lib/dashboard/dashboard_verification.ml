(** Dashboard projection for verification requests.

    Reads [<base_path>/.masc/verifications/*.json] via {!Verification.list_requests}
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

let request_kind_of_output (output : Yojson.Safe.t) : string =
  match output with
  | `Assoc fields ->
      (match List.assoc_opt "request_kind" fields with
       | Some (`String "conflict_triage") -> "conflict_triage"
       | _ -> "normal")
  | _ -> "normal"

let request_summary_of_output (output : Yojson.Safe.t) : string =
  match output with
  | `Assoc fields ->
      (match List.assoc_opt "request_summary" fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

let next_action_of_output (output : Yojson.Safe.t) : string option =
  match output with
  | `Assoc fields ->
      (match List.assoc_opt "next_action" fields with
       | Some (`String s) when String.trim s <> "" -> Some s
       | _ -> None)
  | _ -> None

(** Status + verdict + approver triple. Keeps all three derivations in one
    place so the match is exhaustive over the Verification state machine. *)
type status_bucket =
  | Pending
  | Approved
  | Rejected

let status_bucket_of_request (req : V.verification_request) : status_bucket =
  match req.status with
  | V.Pending | V.Assigned _ -> Pending
  | V.Completed V.Pass -> Approved
  | V.Completed (V.Fail _ | V.Partial _) -> Rejected

let status_bucket_to_string = function
  | Pending -> "pending"
  | Approved -> "approved"
  | Rejected -> "rejected"

let derive_status_fields (req : V.verification_request)
  : string * string option * string * string option =
  (* returns (status, verdict_opt, verdict_reason, approved_by_opt) *)
  match req.status with
  | V.Pending ->
      status_bucket_to_string Pending, None, "", None
  | V.Assigned _ ->
      status_bucket_to_string Pending, None, "", None
  | V.Completed V.Pass ->
      status_bucket_to_string Approved, Some "pass", "", req.verifier
  | V.Completed (V.Fail reason) ->
      status_bucket_to_string Rejected, Some "fail", reason, req.verifier
  | V.Completed (V.Partial (_, reason)) ->
      status_bucket_to_string Rejected, Some "partial", reason, req.verifier

(** Per-request JSON row. *)
let request_to_json (req : V.verification_request) : Yojson.Safe.t =
  let status, verdict_opt, verdict_reason, approved_by =
    derive_status_fields req
  in
  let contract = completion_contract_of_criteria req.criteria in
  let evidence = required_evidence_of_output req.output in
  let task_title = task_title_of_output req.output in
  let request_kind = request_kind_of_output req.output in
  let request_summary = request_summary_of_output req.output in
  let next_action = next_action_of_output req.output in
  `Assoc [
    ("request_id", `String req.id);
    ("task_id", `String req.task_id);
    ("task_title", `String task_title);
    ("request_kind", `String request_kind);
    ("request_summary", `String request_summary);
    ( "next_action",
      match next_action with
      | Some action -> `String action
      | None -> `Null );
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

let now_iso () = Masc_domain.now_iso ()

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

(* ── Summary projection ─────────────────────────────── *)

let max_recent = 20
let default_recent = 3

let clamp_recent r =
  let r = Option.value r ~default:default_recent in
  if r < 0 then 0 else if r > max_recent then max_recent else r

(** Minimal row for the ["recent_rejections"] array — strictly the fields
    a summary consumer needs (who, why, when, which task). Keeps the
    payload small and independent of the full [requests_json] schema so
    future additions to the row shape do not leak into summary. *)
let rejection_row_json (req : V.verification_request) : Yojson.Safe.t =
  let _status, _verdict_opt, verdict_reason, approved_by =
    derive_status_fields req
  in
  let task_title = task_title_of_output req.output in
  `Assoc [
    ("request_id", `String req.id);
    ("task_id", `String req.task_id);
    ("task_title", `String task_title);
    ("keeper",
     match approved_by with
     | Some v -> `String v
     | None -> `Null);
    ("verdict_reason", `String verdict_reason);
    ("created_at", `String (iso_of_unix req.created_at));
  ]

let is_rejected (req : V.verification_request) : bool =
  match req.status with
  | V.Completed (V.Fail _) | V.Completed (V.Partial _) -> true
  | V.Completed V.Pass -> false
  | V.Pending | V.Assigned _ -> false

let bucket_of_status (req : V.verification_request) : string =
  req |> status_bucket_of_request |> status_bucket_to_string

let summary_json ?recent () : Yojson.Safe.t =
  let recent = clamp_recent recent in
  let all = load_requests () in
  let total = List.length all in
  let pending = ref 0 in
  let approved = ref 0 in
  let rejected = ref 0 in
  List.iter (fun req ->
    match status_bucket_of_request req with
    | Pending -> incr pending
    | Approved -> incr approved
    | Rejected -> incr rejected
  ) all;
  let recent_rejections =
    all
    |> List.filter is_rejected
    |> sort_desc
    |> take recent
    |> List.map rejection_row_json
  in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("total", `Int total);
    ("by_status", `Assoc [
      ("pending", `Int !pending);
      ("approved", `Int !approved);
      ("rejected", `Int !rejected);
      (* timed_out reserved for future state-machine variant; always 0 today *)
      ("timed_out", `Int 0);
    ]);
    ("recent_rejections", `List recent_rejections);
  ]
