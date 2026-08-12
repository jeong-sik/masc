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

(** Criteria are the exact completion-contract statements. *)
let completion_contract_of_criteria (criteria : V.criterion list) : string list =
  criteria

(** Read one required current-schema evidence list. Empty arrays are valid;
    missing or malformed fields carry a public projection error and malformed
    arrays are never partially projected. *)
let string_list_of_output field (output : Yojson.Safe.t)
  : string list * string option =
  let missing () =
    [], Some (Printf.sprintf "missing current-schema field %S" field)
  in
  let malformed detail =
    ( [],
      Some (Printf.sprintf
        "malformed current-schema field %S: %s" field detail) )
  in
  let rec strings acc = function
    | [] -> Some (List.rev acc)
    | `String value :: rest -> strings (value :: acc) rest
    | _ -> None
  in
  match output with
  | `Assoc fields ->
      (match List.assoc_opt field fields with
       | Some (`List items) ->
           (match strings [] items with
            | Some values -> values, None
            | None -> malformed "expected an array of strings")
       | Some _ -> malformed "expected an array of strings"
       | None -> missing ())
  | _ -> malformed "verification output must be an object"

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

(** Per-request JSON row. *)
let request_to_json (req : V.verification_request) : Yojson.Safe.t =
  let contract = completion_contract_of_criteria req.criteria in
  let required_artifacts, required_artifacts_error =
    string_list_of_output "required_artifacts" req.output
  in
  (* [submitted_evidence] is the materialized snapshot the completion authority
     read, not the producer's raw reference strings: the submit boundary
     replaces the field with resolved items carrying unreadable markers. The
     store owns that shape and projects it to identity lines; reading it as a
     string array rejected every request on the live store. *)
  let submitted_evidence, submitted_evidence_error =
    match req.output with
    | `Assoc fields ->
      (match List.assoc_opt "submitted_evidence" fields with
       | None -> [], Some "missing current-schema field \"submitted_evidence\""
       | Some value ->
         (match
            Workspace_verification_store.submitted_evidence_identity_lines value
          with
          | Ok lines -> lines, None
          | Error detail ->
            ( []
            , Some
                (Printf.sprintf
                   "malformed current-schema field %S: %s"
                   "submitted_evidence"
                   detail) )))
    | _ -> [], Some "verification output must be an object"
  in
  let evidence_projection_error =
    [required_artifacts_error; submitted_evidence_error]
    |> List.filter_map Fun.id
    |> function
    | [] -> None
    | errors -> Some (String.concat "; " errors)
  in
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
    ( "next_action", Json_util.string_opt_to_json next_action );
    ("created_at", `String (Masc_domain.iso8601_of_unix_seconds req.created_at));
    ("submitted_by", `String req.worker);
    ("completion_contract",
     `List (List.map (fun s -> `String s) contract));
    ("required_artifacts",
     `List (List.map (fun s -> `String s) required_artifacts));
    ("submitted_evidence",
     `List (List.map (fun s -> `String s) submitted_evidence));
    ("evidence_projection_error",
     Json_util.string_opt_to_json evidence_projection_error);
  ]

(* ── Snapshot assembly ──────────────────────────────── *)

(** Load the request scan from the supplied MASC base_path.

    [failwith] is kept for the directory-level error, where the scan produced
    no knowledge at all and a projection would be inventing one. A file the
    schema cannot read is not that case: it arrives in [unreadable] and is
    reported alongside the requests that did read. Before this, one such file
    raised here and the whole endpoint answered 500, which named a single path
    while hiding how many records the reader had actually rejected. *)
let load_scan ~base_path () : V.request_scan =
  match V.list_requests base_path with
  | Ok scan -> scan
  | Error detail -> failwith detail

(* Operator-facing shape for the files the reader could not parse. Emitted on
   every projection that reads the store, so an unreadable record is visible
   without having to correlate a counter against a log line. *)
let unreadable_fields (scan : V.request_scan) =
  [ ("unreadable_total", `Int (List.length scan.V.unreadable))
  ; ( "unreadable"
    , `List (List.map V.unreadable_to_yojson scan.V.unreadable) )
  ]

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

let take = List.take

let fd_pressure_fields () = Keeper_fd_pressure.projection_fields ()

(* Compute the request-listing projection from an already-loaded list.
   Factored out so [proof_compose] can share the disk scan between
   summary and request listing. *)
let requests_json_of_requests ?task_id ~limit (scan : V.request_scan) : Yojson.Safe.t =
  let filtered = filter_by_task_id scan.V.readable task_id in
  let sorted = sort_desc filtered in
  let trimmed = take limit sorted in
  `Assoc
    ([ ("updated_at", `String (Masc_domain.now_iso ()))
     ; ("total", `Int (List.length filtered))
     ; ("requests", `List (List.map request_to_json trimmed))
     ]
     @ unreadable_fields scan
     @ fd_pressure_fields ())

let requests_json ~base_path ?task_id ?limit () : Yojson.Safe.t =
  let limit = clamp_limit limit in
  let scan = load_scan ~base_path () in
  requests_json_of_requests ?task_id ~limit scan

let summary_json ~base_path () : Yojson.Safe.t =
  let scan = load_scan ~base_path () in
  `Assoc
    ([ ("updated_at", `String (Masc_domain.now_iso ()))
     ; ("total", `Int (List.length scan.V.readable))
     ]
     @ unreadable_fields scan
     @ fd_pressure_fields ())

(* Single-load companion for handlers that emit both projections side by side.
   One request-store scan feeds both projections. *)
let proof_compose ~base_path ?limit () : Yojson.Safe.t * Yojson.Safe.t =
  let limit = clamp_limit limit in
  let scan = load_scan ~base_path () in
  let summary =
    `Assoc
      ([ ("updated_at", `String (Masc_domain.now_iso ()))
       ; ("total", `Int (List.length scan.V.readable))
       ]
       @ unreadable_fields scan
       @ fd_pressure_fields ())
  in
  let requests = requests_json_of_requests ~limit scan in
  summary, requests
