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

(* An offset past the end yields an empty page rather than an error: a reader
   paging forward should land on "nothing further", not on a failure.

   A negative offset lands on the first page. Not for safety -- [List.drop]
   returns the whole list on a negative count in 5.5 (it raised in 5.3 only) --
   but for the numbers beside the page: an unclamped [-5] would be echoed as
   [offset] and would make [truncated = total > offset + returned] compare
   against a place the list does not have. The HTTP boundary refuses a
   negative offset before it arrives; an in-process caller that passes one
   gets the first page, reported as the first page. *)
let clamp_offset offset = match offset with
  | Some n when n > 0 -> n
  | Some _ | None -> 0

(* ── Queue view ─────────────────────────────────────── *)

(** Which question the caller asks of the same directory.

    The store has no removal path, so [verifications/] holds every request
    ever submitted, including those whose task finished weeks ago. Reading it
    as one list answers "what was ever submitted", which is not the question
    an operator looking for work is asking. The two questions are named rather
    than separated by a column the reader has to filter by eye. *)
type requested_view =
  | Ask_awaiting
  | Ask_all

let requested_view_to_string = function
  | Ask_awaiting -> "awaiting"
  | Ask_all -> "all"

(** An unrecognised name is refused rather than defaulted. A caller that
    misspells the parameter and silently receives the whole history has been
    told nothing, and the history is the larger and more misleading of the two
    answers. *)
let requested_view_of_string = function
  | "awaiting" -> Ok Ask_awaiting
  | "all" -> Ok Ask_all
  | other ->
    Error
      (Printf.sprintf
         "unknown view %S: expected %S or %S"
         other
         (requested_view_to_string Ask_awaiting)
         (requested_view_to_string Ask_all))

(** What the backlog is waiting on, read by the caller and handed in.

    This module reads the request store and nothing else, so the join key
    arrives rather than being fetched -- the projection stays a pure function
    of its arguments and its tests need no backlog on disk.

    [Backlog_unreadable] is carried instead of collapsing to an empty list:
    "the backlog names nothing" and "the backlog could not be read" are
    different answers, and only the first one means there is no work. *)
type awaiting_task =
  { request_id : string
  ; intent : Masc_domain.verification_intent
  }

type awaiting_join =
  | Backlog_read of { live : awaiting_task list }
  | Backlog_recovered of
      { live : awaiting_task list
      ; detail : string
      }
      (** The primary backlog did not read and a [.last-good] snapshot did.
          The queue is computed, and is as old as that snapshot: a task that
          submitted after it is not in this answer. Folded into
          [Backlog_read] this was a queue that looked current and was not. *)
  | Backlog_unreadable of string

(** The view with everything it needs to be answered. [Ask_awaiting] cannot be
    resolved without the backlog, so the resolved form carries it and a caller
    cannot ask for the queue while holding no join. *)
type queue_view =
  | Awaiting_operator of awaiting_join
  | All_requests

let queue_view_requested = function
  | Awaiting_operator _ -> Ask_awaiting
  | All_requests -> Ask_all

(** The request id each awaiting task is waiting on.

    [AwaitingVerification] carries that id, so the queue is a join on identity
    rather than a scan for tasks whose status happens to match. The difference
    is not cosmetic: a task re-submitted N times leaves N records in the store
    and is waiting on exactly one of them. Matching by status alone drew all N.

    Every status is named so a new one has to be given an answer here rather
    than inheriting "not waiting" from a catch-all. *)
let awaiting_tasks (backlog : Masc_domain.backlog) : awaiting_task list =
  List.filter_map
    (fun (task : Masc_domain.task) ->
      match task.Masc_domain.task_status with
      | Masc_domain.AwaitingVerification { verification_id; intent; _ } ->
        Some { request_id = verification_id; intent }
      | Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ -> None)
    backlog.Masc_domain.tasks

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

(** Per-request JSON row. *)
(* [intent] is the task's pending intent when the caller joined the backlog
   (the awaiting view) and [None] when it did not (the history view). The
   two are told apart on the wire as a name versus [null]: a cancellation
   waits on this queue beside completions and only an operator's verdict
   clears it, so a row that could not say which it is sent the operator to
   the task file. *)
let request_to_json ~(intent : Masc_domain.verification_intent option)
    (req : V.verification_request) : Yojson.Safe.t =
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
  `Assoc [
    ("request_id", `String req.id);
    ("task_id", `String req.task_id);
    ("task_title", `String task_title);
    ("created_at", `String (Masc_domain.iso8601_of_unix_seconds req.created_at));
    ("submitted_by", `String req.worker);
    ("intent",
     (match intent with
      | Some intent -> `String (Masc_domain.verification_intent_to_string intent)
      | None -> `Null));
    ("completion_contract",
     `List (List.map (fun s -> `String s) contract));
    ("required_artifacts",
     `List (List.map (fun s -> `String s) required_artifacts));
    ("submitted_evidence",
     `List (List.map (fun s -> `String s) submitted_evidence));
    ("evidence_projection_error",
     Json_util.string_opt_to_json evidence_projection_error);
    (* The producer's whole claim when it gave up. A one-way signal: a record
       carrying this is a stop, and only the stop path writes it. Its absence
       is not "a completion" — stops submitted before the record kept the copy
       have none either, and saying "completion" about those would be the
       queue inventing an answer the record does not hold. *)
    (Workspace_verification_store.cancellation_reason_field,
     Json_util.string_opt_to_json
       (Workspace_verification_store.cancellation_reason_of_output req.output));
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
let id_set (requests : V.verification_request list) =
  let seen = Hashtbl.create (List.length requests) in
  List.iter
    (fun (r : V.verification_request) -> Hashtbl.replace seen r.V.id ())
    requests;
  seen

(** Apply the view, and report what the join could not account for.

    An id the backlog is waiting on that names no record in the store is a
    task waiting on something that is not there. Dropping it would leave a
    task stuck with nothing on any screen to say why, so it is counted and
    listed rather than filtered away.

    [Backlog_unreadable] yields an empty queue carrying the reason. The
    alternative -- falling back to the unfiltered history -- would answer a
    request for "what is waiting on me" with every request ever submitted,
    which reads as work rather than as a failure to look. *)
let awaiting_fields ~limit ~backlog_error ~backlog_recovery ~unresolved =
  (* One key set for every arm of this view. A reader of
     [awaiting_unresolved_total] used to get a number on success and nothing
     at all in the failure that field exists to describe. *)
  [ ("backlog_error", Json_util.string_opt_to_json backlog_error)
  ; ("backlog_recovery", Json_util.string_opt_to_json backlog_recovery)
  ; ("awaiting_unresolved_total", `Int (List.length unresolved))
    (* The count is exact; the list is one page of it. Unbounded, it rode
       every page of every response -- which is the payload this projection
       grew an offset to bound. *)
  ; ( "awaiting_unresolved"
    , `List (List.map (fun id -> `String id) (take limit unresolved)) )
  ]

(** Apply the view, and report what the join could not account for.

    [store] is the whole readable scan, not [requests]: the difference is
    "ids the backlog waits on that name no record anywhere", and taking it
    against a task-filtered list reported every *other* task's live id as
    missing. *)
let filter_by_view ~limit (view : queue_view)
    ~(store : V.verification_request list)
    (requests : V.verification_request list)
  : V.verification_request list
    * (string * Yojson.Safe.t) list
    * (string -> Masc_domain.verification_intent option) =
  let no_join _ = None in
  let join ~recovery (live : awaiting_task list) =
    let wanted = Hashtbl.create (List.length live) in
    List.iter
      (fun (t : awaiting_task) -> Hashtbl.replace wanted t.request_id t.intent)
      live;
    let kept =
      List.filter
        (fun (r : V.verification_request) -> Hashtbl.mem wanted r.V.id)
        requests
    in
    let present = id_set store in
    let unresolved =
      List.filter_map
        (fun (t : awaiting_task) ->
          if Hashtbl.mem present t.request_id then None else Some t.request_id)
        live
    in
    ( kept
    , awaiting_fields ~limit ~backlog_error:None ~backlog_recovery:recovery
        ~unresolved
    , Hashtbl.find_opt wanted )
  in
  match view with
  | All_requests -> requests, [], no_join
  | Awaiting_operator (Backlog_unreadable detail) ->
    ( []
    , awaiting_fields ~limit ~backlog_error:(Some detail)
        ~backlog_recovery:None ~unresolved:[]
    , no_join )
  | Awaiting_operator (Backlog_read { live }) -> join ~recovery:None live
  | Awaiting_operator (Backlog_recovered { live; detail }) ->
    join ~recovery:(Some detail) live

let requests_json_of_requests ?task_id ~limit ~offset ~view
    (scan : V.request_scan) : Yojson.Safe.t =
  let filtered = filter_by_task_id scan.V.readable task_id in
  let in_view, view_fields, intent_of =
    filter_by_view ~limit view ~store:scan.V.readable filtered
  in
  let sorted = sort_desc in_view in
  let total = List.length sorted in
  let page = sorted |> List.drop offset |> take limit in
  `Assoc
    ([ ("updated_at", `String (Masc_domain.now_iso ()))
     ; ("view", `String (requested_view_to_string (queue_view_requested view)))
     ; ("total", `Int total)
     ; ("offset", `Int offset)
     ; ("returned", `Int (List.length page))
     (* Whether a further page exists, computed here so a reader does not have
        to derive it from three numbers and get the boundary wrong. *)
     ; ("truncated", `Bool (total > offset + List.length page))
     ; ( "requests"
       , `List
           (List.map
              (fun (r : V.verification_request) ->
                request_to_json ~intent:(intent_of r.V.id) r)
              page) )
     ]
     @ view_fields
     @ unreadable_fields scan
     @ fd_pressure_fields ())

let requests_json ~base_path ?task_id ?limit ?offset ?view () : Yojson.Safe.t =
  let limit = clamp_limit limit in
  let offset = clamp_offset offset in
  let view = match view with Some v -> v | None -> All_requests in
  let scan = load_scan ~base_path () in
  requests_json_of_requests ?task_id ~limit ~offset ~view scan

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
  let requests =
    requests_json_of_requests ~limit ~offset:0 ~view:All_requests scan
  in
  summary, requests
