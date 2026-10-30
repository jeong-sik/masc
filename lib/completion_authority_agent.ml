(** System LLM completion-authority lane.

    This is deliberately an application-owned LLM agent rather than a Keeper:
    it has no Keeper identity, no Keeper task action, and no Keeper lifecycle.
    The only durable mutation it can perform is the typed completion-verdict
    boundary after the verification request and evidence identities match. *)

open Result.Syntax

(* RFC-0361 D7(b): fixed authority identity — every judgement carries the
   same actor string (the [verifier_exact] lane id) so verdicts aggregate by
   actor; run identity stays with the per-review [verification_id]. *)
let authority_actor = Masc_domain.completion_authority_actor Verifier_review_publication.authority

(* How many operator-disagreement examples ride along in the judge's prompt.
   Few-shot selection puts false positives first, so the examples that cost
   the most (an approve a human overturned) are the ones that survive the
   cut. *)
let judge_few_shot_examples = 3

type review_key =
  { task_id : string
  ; verification_id : string
  }

module Review_keys = Set.Make (struct
  type t = review_key

  let compare left right =
    match String.compare left.task_id right.task_id with
    | 0 -> String.compare left.verification_id right.verification_id
    | order -> order
  ;;
end)

type retry_batch =
  { keys : Review_keys.t
  ; sweep : bool
  }

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; wake : Eio.Condition.t
  ; sweep_pending : bool Atomic.t
      (** A whole-backlog read is due. Boot recovery and a failed backlog read
          are the only things that need one: they have no key to aim at. *)
  ; rejection_delivery_pending : bool Atomic.t
  ; rejection_retry_pending : bool Atomic.t
  ; targets : review_key list Atomic.t
      (** Verifications a submission or a retryable deferral asked for by name.
          The submission hook already receives [task], [assignee] and
          [verification_id]; carrying them here is what keeps one submission
          from re-reviewing every other awaiting Task. *)
  ; retry_pending : retry_batch option Atomic.t
      (** [Some] owns one interval timer and every retry admitted before its
          atomic drain. The timer flag cannot outlive or forget its work. *)
  ; retry_interval_sec : float
  ; in_flight : review_key list Atomic.t
  ; review_slots : Eio.Semaphore.t
  }

let active_runtime : runtime option Atomic.t = Atomic.make None

let review_key_equal left right =
  String.equal left.task_id right.task_id
  && String.equal left.verification_id right.verification_id
;;

let claim_review (runtime : runtime) key =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    if List.exists (review_key_equal key) current
    then false
    else if Atomic.compare_and_set runtime.in_flight current (key :: current)
    then true
    else loop ()
  in
  loop ()
;;

let release_review (runtime : runtime) key =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    let next = List.filter (fun candidate -> not (review_key_equal candidate key)) current in
    if List.length next = List.length current
    then ()
    else if Atomic.compare_and_set runtime.in_flight current next
    then ()
    else loop ()
  in
  loop ()
;;

(** What one wake of the daemon is allowed to look at. A submission and a
    retryable deferral both name the verification they mean, so they get
    [Targets]. Boot and a failed backlog read have nothing to name, so they get
    [Whole_backlog]. Keeping the two apart is what stops one submission from
    re-reviewing every other awaiting Task. *)
type scan_scope =
  | Whole_backlog
  | Targets of review_key list

(* Pure: the awaiting entries one scope admits. [Whole_backlog] admits all of
   them; [Targets] admits only the named keys, and names a key at most once even
   if it was requested repeatedly before the daemon woke. *)
let entries_in_scope ~scope entries =
  match scope with
  | Whole_backlog -> entries
  | Targets keys ->
    List.filter
      (fun (key, _) -> List.exists (review_key_equal key) keys)
      entries
;;

let take_targets (runtime : runtime) =
  let rec loop () =
    let current = Atomic.get runtime.targets in
    if current = []
    then []
    else if Atomic.compare_and_set runtime.targets current []
    then current
    else loop ()
  in
  loop ()
;;

let evidence_refs_of_output = function
  | `Assoc fields ->
    (match List.assoc_opt "evidence_refs" fields with
     | Some (`List values) ->
       let rec collect index acc = function
         | [] -> Ok (List.rev acc)
         | (`String value) :: rest -> collect (index + 1) (value :: acc) rest
         | value :: _ ->
           Error
             (Printf.sprintf
                "verification request output evidence_refs[%d] must be a string, got %s"
                index
                (Json_util.excerpt value))
       in
       collect 0 [] values
     | Some value ->
       Error
         (Printf.sprintf
            "verification request output evidence_refs must be a JSON array, got %s"
            (Json_util.excerpt value))
     | None -> Error "verification request output has no evidence_refs")
  | other ->
    Error
      (Printf.sprintf
         "verification request output must be a JSON object, got %s"
         (Json_util.excerpt other))
;;

let completion_verdict_of_review = function
  | Task.Anti_rationalization.Approve _ -> Masc_domain.Verdict_approved
  | Task.Anti_rationalization.Reject reason ->
    Masc_domain.Verdict_rejected { reason }
;;

(* The notes projection of one unread image: the reference the producer
   submitted and the store's reason, one JSON shape per constructor. The
   ceiling case keeps the numbers it was decided on; the unreadable case
   keeps the OS message, which names the filed body under the masc dir, not
   anything in the producer's tree. *)
let unread_image_to_yojson
    ((reference, reason) : string * Workspace_verification_store.read_binary_error)
  : Yojson.Safe.t =
  let reason_json =
    match reason with
    | Workspace_verification_store.Not_binary -> `Assoc [ "kind", `String "not_binary" ]
    | Workspace_verification_store.Body_not_filed ->
      `Assoc [ "kind", `String "body_not_filed" ]
    | Workspace_verification_store.Body_unreadable detail ->
      `Assoc [ "kind", `String "body_unreadable"; "detail", `String detail ]
    | Workspace_verification_store.Body_identity_mismatch
        { expected_bytes; actual_bytes; expected_sha256; actual_sha256 } ->
      `Assoc
        [ "kind", `String "body_identity_mismatch"
        ; "expected_bytes", `Int expected_bytes
        ; "actual_bytes", `Int actual_bytes
        ; "expected_sha256", `String expected_sha256
        ; "actual_sha256", `String actual_sha256
        ]
    | Workspace_verification_store.Over_delivery_ceiling { bytes; ceiling } ->
      `Assoc
        [ "kind", `String "over_delivery_ceiling"
        ; "bytes", `Int bytes
        ; "ceiling", `Int ceiling
        ]
  in
  `Assoc [ "reference", `String reference; "reason", reason_json ]
;;

let review_notes
    ~(request : Verification.verification_request)
    ~evidence_access
    ~unread_images
    ~result
    ~authority =
  let verdict =
    match result.Task.Anti_rationalization.verdict with
    (* Stays the bare "approve" token: [Dashboard_harness_health] and the
       label decoders read this notes field as that exact one-piece string. The
       stated reason travels to the run registry instead, where the outcome has
       a field for it. *)
    | Some (Task.Anti_rationalization.Approve _) -> `String "approve"
    | Some (Task.Anti_rationalization.Reject reason) ->
      `Assoc [ "kind", `String "reject"; "reason", `String reason ]
    | None -> `Null
  in
  let review =
    `Assoc
      [ "evaluator_runtime", `String result.evaluator_runtime
      ; "generator_runtime",
        (match result.generator_runtime with
         | Some runtime -> `String runtime
         | None -> `Null)
      ; "gate", `String (Task.Anti_rationalization.gate_to_string result.gate)
      ; "evaluator_execution", (match result.evaluator_execution with
          | None -> `Null | Some identity -> Runtime_response_identity.to_yojson identity)
      ; "verdict", verdict
      ; "authority_kind", `String (Masc_domain.completion_authority_kind authority)
      ; "authority_actor", `String (Masc_domain.completion_authority_actor authority)
      ; "unread_images", `List (List.map unread_image_to_yojson unread_images)
      ]
  in
  Yojson.Safe.pretty_to_string
    (`Assoc
       [ ( "verification_request"
         , `Assoc
             [ "id", `String request.id
             ; "task_id", `String request.task_id
             ; "worker", `String request.worker
             ; "created_at", `Float request.created_at
             ] )
       ; ( "submitted_evidence_metadata"
         , Workspace_verification_store.submitted_evidence_access_metadata_to_yojson
             evidence_access )
       ; "review", review
       ])
;;

let required_string_list_field ~context name fields =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | (`String value) :: rest -> collect (index + 1) (value :: acc) rest
      | value :: _ ->
        Error
          (Printf.sprintf
             "%s %s[%d] must be a string, got %s"
             context
             name
             index
             (Json_util.excerpt value))
    in
    collect 0 [] values
  | Some value ->
    Error
      (Printf.sprintf
         "%s %s must be a JSON array, got %s"
         context
         name
         (Json_util.excerpt value))
  | None ->
    Error (Printf.sprintf "%s has no %s" context name)
;;

(* The question to put, and the material it needs: a completion weighed
   against its contract and artifacts. The request supplies both. *)
let verdict_question_of_request (request : Verification.verification_request) =
  match request.output with
  | `Assoc fields ->
    let* required_evidence =
      required_string_list_field
        ~context:"verification request output"
        "required_artifacts"
        fields
    in
    Ok
      { Task.Anti_rationalization.completion_contract =
          (match request.criteria with
           | [] -> None
           | descriptions -> Some descriptions)
      ; required_evidence
        (* Both filled at the review site, where the snapshot and the
           calibration ledger are read. This function maps a request to a
           question and reads no store. *)
      ; evidence_posture = Task.Anti_rationalization.Note_only
      ; few_shot_block = ""
      }
  | other ->
    Error
      (Printf.sprintf
         "verification request output must be a JSON object, got %s"
         (Json_util.excerpt other))
;;

(* The evidence posture, computed from the fixed snapshot this request was
   submitted with. The arithmetic is the judge prompt's rules 3 and 4 made
   typed: an artifact the judge cannot open whole counts as nothing. An
   unavailable snapshot is the same posture as an empty one — the judge
   already sees the typed reason beside the question. *)
let evidence_posture_of_snapshot
      (snapshot : Workspace_verification_store.submitted_evidence_access) =
  let usable =
    match snapshot with
    | Workspace_verification_store.Evidence_unavailable _ -> 0
    | Workspace_verification_store.Evidence_available { request = _; items } ->
      items
      |> List.filter (function
           | Workspace_verification_store.Evidence_artifact
               { reference = _; content = _; bytes = _; truncated = false } ->
             true
           | Workspace_verification_store.Evidence_collaboration _
           | Workspace_verification_store.Evidence_artifact_binary _ ->
             (* A binary item is judgeable on its own terms: the hash, the
                size, and the filed body are the facts the verdict can rest
                on (RFC-0436 §4.1). *)
             true
           | Workspace_verification_store.Evidence_artifact { reference = _; content = _; bytes = _; truncated = true }
           | Workspace_verification_store.Evidence_invalid_reference
           | Workspace_verification_store.Evidence_note _
           | Workspace_verification_store.Evidence_artifact_unreadable _ -> false)
      |> List.length
  in
  if usable = 0 then Task.Anti_rationalization.Note_only
  else Task.Anti_rationalization.Usable_artifacts usable
;;

(* RFC-0436 §4.3/§4.4: what the judge receives of the binary image
   artifacts. [images] are the ones attached as image blocks. [unread] are
   the image-format artifacts whose filed body did not come back, each with
   the store's typed reason: the judge rests on the reference-and-hash line
   for those, and the committed verdict names them so an operator reading
   the notes knows which pictures the judge never saw. A non-image binary
   (a diff, an archive) is in neither list — it was never an attachment
   candidate and its reference and hash stay in the prompt text. Before
   this record existed the read failure was dropped on the floor and the
   verdict read as if every image had been looked at (F401). *)
type evidence_images =
  { images : Task.Anti_rationalization.evidence_image list
  ; unread : (string * Workspace_verification_store.read_binary_error) list
  }

let evidence_images_of_snapshot ~base_path
      (snapshot : Workspace_verification_store.submitted_evidence_access) :
      evidence_images =
  let module Store = Workspace_verification_store in
  match snapshot with
  | Store.Evidence_unavailable _ -> { images = []; unread = [] }
  | Store.Evidence_available { request = _; items } ->
    let images, unread =
      List.fold_left
        (fun (images, unread) (item : Store.submitted_evidence_item) ->
           match item with
           | Store.Evidence_artifact_binary
               { reference; bytes; sha256; format; body = _ } ->
             (match Store.image_media_type_of_binary_format format with
              | None -> images, unread
              | Some media_type -> (
                match Store.read_binary_body_base64 ~base_path item with
                | Error reason -> images, (reference, reason) :: unread
                | Ok body_base64 ->
                  ( Task.Anti_rationalization.
                      { image_reference = reference
                      ; image_sha256 = sha256
                      ; image_bytes = bytes
                      ; image_media_type = media_type
                      ; image_body_base64 = body_base64
                      }
                    :: images
                  , unread )))
           | Store.Evidence_collaboration _ -> images, unread
           | Store.Evidence_note _ -> images, unread
           | Store.Evidence_artifact _ -> images, unread
           | Store.Evidence_invalid_reference -> images, unread
           | Store.Evidence_artifact_unreadable _ -> images, unread)
        ([], [])
        items
    in
    { images = List.rev images; unread = List.rev unread }
;;

(* The request owns the durable snapshot; the judge receives its transport
   projection below. Remove every copy of that output member from this local
   request projection so the stored bodies cannot bypass transport omissions.
   [Verification_protocol.create_submit_request] (via
   [Tool_task_completion_review.verification_evidence_fields]) constructs
   [request.output] in one place with ["submitted_evidence"] only at the top
   level; if that envelope ever nests the key deeper, this filter must descend
   to match (#43588). *)
let completion_notes_of_evidence
      ~(request : Verification.verification_request)
      ~evidence_access
  =
  let output =
    match request.output with
    | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (name, _) -> not (String.equal name "submitted_evidence" || String.equal name "producer_execution"))
           fields)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
      as output -> output
  in
  let request_for_judge = { request with output } in
  Yojson.Safe.to_string
    (`Assoc
       [ "verification_request", Verification.request_to_yojson request_for_judge
       ; ( "submitted_evidence_access"
         , Workspace_verification_store
            .submitted_evidence_access_transport_to_yojson
             evidence_access )
       ])
;;

type prepared_review =
  { request : Verification.verification_request
  ; producer_execution : Runtime_response_identity.t option
  ; evidence_access : Workspace_verification_store.submitted_evidence_access
  ; review_request : Task.Anti_rationalization.review_request
  ; unread_images : (string * Workspace_verification_store.read_binary_error) list
        (* Image artifacts whose body the judge did not receive, with the
           store's reason; committed into the verdict notes. *)
  ; question : Task.Anti_rationalization.verdict_question
  }

(* Artifact references the store looked for and did not find. The snapshot layer
   already resolves every reference against the producer's root and answers
   [Evidence_artifact_unreadable] for the ones that lead nowhere, so this only
   collects that answer; it does not decide what counts as readable. Only
   [Evidence_missing] is collected: a file that exists but cannot be read is a
   different situation, and the reviewer is the right place to weigh it.

   A reference that names no file is not weak evidence for the authority to
   weigh, it is a submission with nothing behind it, and no reviewer can read
   what was never written. Left to the reviewer it becomes a judgement call that
   can land either way on the same evidence: task-808 was refused at 10:55 for
   an artifact the store reported missing, and approved at 10:59 with the file
   still absent. *)

let prepare_review
      ~(config : Workspace_utils_backend_setup.config)
      ~(task : Masc_domain.task)
      ~assignee
      ~verification_id
      ~(authority : Masc_domain.completion_authority)
  : (prepared_review, string) result
  =
  let* request = Verification.load_request config.base_path verification_id in
  if not (String.equal request.id verification_id)
  then
    Error
      (Printf.sprintf
         "verification request id mismatch (path=%s payload=%s)"
         verification_id
         request.id)
  else if not (String.equal request.task_id task.id)
  then
    Error
      (Printf.sprintf
         "verification request task mismatch (request=%s awaiting=%s)"
         request.task_id
         task.id)
  else if not (String.equal request.worker assignee)
  then
    Error
      (Printf.sprintf
         "verification request worker mismatch (request=%s awaiting=%s)"
         request.worker
         assignee)
  else
    let evidence_access =
      Workspace_verification_store.inspect_submitted_evidence_for_authority
        ~base_path:config.base_path
        ~request_id:verification_id
        ~task_id:task.id
        ~task_worker:assignee
        ~authority
    in
    match evidence_access with
    | Workspace_verification_store.Evidence_unavailable { request_id; reason } ->
      Error
        (Printf.sprintf
           "submitted evidence unavailable: %s"
           (Workspace_verification_store.evidence_access_failure_to_string
              ~request_id
              reason))
    | Workspace_verification_store.Evidence_available { request = header; items } ->
      if not (String.equal header.id verification_id)
      then
        Error
          (Printf.sprintf
             "submitted evidence header id mismatch (expected=%s actual=%s)"
             verification_id
             header.id)
      else if not (String.equal header.task_id task.id)
      then
        Error
          (Printf.sprintf
             "submitted evidence header task mismatch (expected=%s actual=%s)"
             task.id
             header.task_id)
      else if not (String.equal header.worker assignee)
      then
        Error
          (Printf.sprintf
             "submitted evidence header worker mismatch (expected=%s actual=%s)"
             assignee
             header.worker)
      else
        let producer_execution = match Verification.producer_execution request with
          | Ok identity -> identity
          | Error detail ->
            Log.Task.warn "[verification-submit-provenance] request=%s unknown: %s" request.id detail;
            None in
        let* evidence_refs = evidence_refs_of_output request.output in
        let* question = verdict_question_of_request request in
        (* An artifact reference the store could not read is carried here,
           not refused here.

           The three header checks above are identity: this payload is not the
           one this review is for, and no reviewer can repair that. An
           unreadable artifact is a different kind of fact. The store resolves
           a reference against the producer's sandbox root only, so a path the
           submitter wrote relative to a checkout misses even when the file is
           right there — [Evidence_missing] answers the path that was asked
           for, not whether the work exists.

           Refusing here made that miss terminal. [prepare_review] runs before
           the lookup surface is built, so no evaluator ran, no verdict was
           committed, and [observe_rejection_wakeup] fires only on a committed
           [Verdict_rejected] — the producer was never told. The outcome
           recorded as [Infrastructure_unavailable], which schedules no retry.
           The Task then sat in [AwaitingVerification] until an operator
           noticed (task-568, task-785, task-845, 2026-08-29). RFC-0337
           (Withdrawn) already removed the hierarchy where evidence shape
           rejects work ahead of the judge; this was that hierarchy again,
           minus the notification.

           The judge is equipped for it: [submitted_evidence_access] carries
           each unreadable item as a typed [artifact_unreadable] with its
           reference and reason, and the judge holds Read/Grep on the same
           root plus a [root_layout] naming every checkout under it.
           [verification.lookup.producer_tree] tells it to prefix a
           checkout-relative path and to establish the tree's shape before
           calling a path absent. A REJECT from there reaches the producer. *)
        let completion_notes =
          completion_notes_of_evidence ~request ~evidence_access
        in
        let { images = evidence_images; unread = unread_images } =
          evidence_images_of_snapshot ~base_path:config.base_path evidence_access
        in
        Ok
          { request
          ; producer_execution
          ; evidence_access
          ; review_request =
              { task_title = task.title
              ; task_description = task.description
              ; completion_notes
              ; agent_name = assignee
              ; task_id = task.id
              ; evidence_refs
              ; evidence_images
              }
          ; unread_images
          ; question
          }
;;

(* RFC-0361 D7(b): the one authority identity every review commits under. *)
let system_authority = Verifier_review_publication.authority

(* What one review attempt asks of the scheduler. This is a request: whether
   a retry is armed, and how soon, is known only after the scheduler answers
   ([retry_admission]). *)
type retry_request =
  | Retry_requested
  | Observe_original_requested
  | No_retry_requested

(* What the scheduler did with one request. [Armed_timer]: this request
   forked the timer, which fires after the full interval. [Joined_running_timer]:
   the request added keys to a batch whose timer was already running.
   [Already_pending]: the pending batch already covered every key. *)
type retry_admission =
  | Armed_timer
  | Joined_running_timer
  | Already_pending

(* What happened to the retry after the attempt was recorded: the value the
   Board post is projected from. *)
type retry_scheduling =
  | Retry_not_requested
  | Retry_admitted of retry_admission

(** Why a review stopped without a verdict. One constructor per way the Task
    is left waiting on a producer, an operator, or the lane's own retry; the
    registry row, the WARN line and the Board notice are all read off this
    sum, so none of them can say something the others do not. Only
    [Not_reviewed] can request a retry: the evaluator's typed candidate
    failures are the only automatic-retry authority, so no other stop can ask
    for one. *)
type stop_cause =
  | Infrastructure_unavailable of
      { stage : Verification_run_registry.infrastructure_stage
      ; detail : string
      }
  | Commit_failed of { detail : string }
  | Not_reviewed of
      { gate : string
      ; detail : string
      ; evaluator_runtime : string
      ; retryable_runtimes : string list
          (** Candidates whose typed failure passes with time: a transient
              error, or a provider rest whose end is known
              ([Task.Anti_rationalization.review_result]). A non-empty list
              requests the retry, and their recorded path rests date it. *)
      ; model_absent_runtimes : string list
          (** Candidates whose typed refusal was model-absence (a retired or
              unknown model): permanent for the unchanged request, excluded
              from [retryable_runtimes], and named here so the stall record
              carries per-candidate outcomes (2026-10-07 audit F-02). *)
      }
  | Execution_pending of { detail : string }
  | Execution_repair_required of { detail : string }
  | Raised of { detail : string }

type process_outcome =
  | Committed
  | Superseded_by of { authority : string }
  | Stalled of stop_cause

(* The one place that reads the evaluator's retryability. A candidate whose
   failure passes with time is the only automatic-retry authority; a review
   with none leaves the next move to the producer, the operator, or the
   whole-backlog sweep. *)
let retry_request_of_stop_cause : stop_cause -> retry_request = function
  | Execution_pending _ -> Observe_original_requested
  | Not_reviewed { retryable_runtimes = _ :: _; _ } -> Retry_requested
  | Not_reviewed { retryable_runtimes = []; _ }
  | Execution_repair_required _ | Infrastructure_unavailable _ | Commit_failed _ | Raised _ -> No_retry_requested
;;

let registry_outcome_of_stop_cause : stop_cause -> Verification_run_registry.outcome
  = function
  | Infrastructure_unavailable { stage; detail } ->
    Verification_run_registry.Infrastructure_unavailable { stage; detail }
  | Commit_failed { detail } -> Verification_run_registry.Commit_failed { detail }
  | Not_reviewed { gate; detail; model_absent_runtimes; _ } ->
    (* Display-only suffix naming permanently refused candidates; never
       matched. The typed field on [stop_cause] is the machine-readable form. *)
    let detail =
      if model_absent_runtimes = []
      then detail
      else Printf.sprintf "%s | model_absent=%s" detail (String.concat "," model_absent_runtimes)
    in
    Verification_run_registry.Not_reviewed { gate; detail }
  | Execution_pending {detail} -> Verification_run_registry.Execution_pending {detail}
  | Execution_repair_required {detail} -> Verification_run_registry.Execution_repair_required {detail}
  | Raised { detail } -> Verification_run_registry.Raised { detail }
;;

(* No verdict means nobody judged this submission. Whether the lane retries
   on its own is read off the evaluator's typed candidate failures that this
   cause carries; the WARN line and the Board notice follow in
   [process_task], after the run row is recorded and the scheduler has
   answered, so both describe the timer that exists rather than the one this
   attempt asked for. *)
let not_reviewed_of_result (result : Task.Anti_rationalization.review_result) =
  let gate = Task.Anti_rationalization.gate_to_string result.gate in
  (* Both arms are real descriptions, not a default standing in for an
     unknown: the reviewer's own fallback text when it produced one, the gate
     name when it did not. Written as a match so neither arm hides inside an
     [Option.value ~default]. *)
  let detail =
    match result.fallback_reason with
    | Some reason -> reason
    | None -> gate
  in
  Not_reviewed
    { gate
    ; detail
    ; evaluator_runtime = result.evaluator_runtime
    ; retryable_runtimes = result.retryable_runtimes
    ; model_absent_runtimes = result.model_absent_runtimes
    }
;;

(* The constructor name plus the payload an operator filters on. The line
   hinges on the constructor, never on the word "deferred" alone. *)
let stop_cause_label = function
  | Infrastructure_unavailable { stage; _ } ->
    Printf.sprintf
      "Infrastructure_unavailable{stage=%s}"
      (Verification_run_registry.infrastructure_stage_label stage)
  | Commit_failed _ -> "Commit_failed"
  | Not_reviewed { gate; evaluator_runtime; _ } ->
    Printf.sprintf "Not_reviewed{gate=%s,slot=%s}" gate evaluator_runtime
  | Execution_pending _ -> "Execution_pending"
  | Execution_repair_required _ -> "Execution_repair_required"
  | Raised _ -> "Raised"
;;

let stop_cause_detail = function
  | Infrastructure_unavailable { detail; _ }
  | Commit_failed { detail }
  | Not_reviewed { detail; _ }
  | Execution_pending {detail} | Execution_repair_required {detail}
  | Raised { detail } -> detail
;;

(* The Board notice keys its repeat check on [gate]: a reviewed stop keeps
   the evaluator's gate name, every other stop is keyed by its constructor. *)
let stalled_gate = function
  | Not_reviewed { gate; _ } -> gate
  | (Execution_pending _ | Execution_repair_required _ | Infrastructure_unavailable _ | Commit_failed _ | Raised _) as cause ->
    stop_cause_label cause
;;

(* The Board disposition for one stall, from what the scheduler reported. A
   timer this stall armed fires after the lane's full interval; a timer it
   joined, or one already holding its key, fires when it fires. *)
let stall_disposition_of_scheduling ~retry_interval_sec
  : retry_scheduling -> Verification_protocol.stall_disposition
  = function
  | Retry_not_requested -> Verification_protocol.No_retry_armed
  | Retry_admitted Armed_timer ->
    Verification_protocol.Retry_scheduled
      { delay = Verification_protocol.Full_interval { seconds = retry_interval_sec } }
  | Retry_admitted (Joined_running_timer | Already_pending) ->
    Verification_protocol.Retry_scheduled { delay = Verification_protocol.Shared_timer }
;;

(* The delay as the log line spells it. The Board sentence spells the same
   value in [Verification_protocol.retry_delay_sentence]; both read one
   [retry_delay]. *)
let retry_delay_field = function
  | Verification_protocol.Full_interval { seconds } -> Printf.sprintf "in_sec=%.1f" seconds
  | Verification_protocol.Shared_timer -> "in=shared_timer"
;;

(* The one WARN a review without a verdict writes. Its template is chosen by
   the same [stall_disposition] the Board sentence is rendered from, so the
   line and the post cannot disagree about what happens next: a retry the
   scheduler armed says so and how soon; anything else names the stop and
   who must act. *)
let stall_log_line ~task_id ~verification_id ~cause ~disposition =
  match disposition with
  | Verification_protocol.Retry_scheduled { delay } ->
    Printf.sprintf
      "system LLM completion authority will retry: %s task_id=%s verification_id=%s %s authority=%s reason=%s"
      (stop_cause_label cause)
      task_id
      verification_id
      (retry_delay_field delay)
      (Masc_domain.completion_authority_actor system_authority)
      (stop_cause_detail cause)
  | Verification_protocol.Original_observation_scheduled {delay} ->
    Printf.sprintf "system LLM completion authority will observe original task_id=%s verification_id=%s %s reason=%s"
      task_id verification_id (retry_delay_field delay) (stop_cause_detail cause)
  | Verification_protocol.Original_repair_required ->
    Printf.sprintf "system LLM completion authority requires original reconciliation task_id=%s verification_id=%s reason=%s"
      task_id verification_id (stop_cause_detail cause)
  | Verification_protocol.No_retry_armed ->
    Printf.sprintf
      "system LLM completion authority stopped: %s; producer or operator must act task_id=%s verification_id=%s authority=%s reason=%s"
      (stop_cause_label cause)
      task_id
      verification_id
      (Masc_domain.completion_authority_actor system_authority)
      (stop_cause_detail cause)
;;

(* Writes the WARN, then projects the same disposition to the Board through
   [notify]. The WARN is the lane's own record and goes first, so no Board
   effect can keep it from being written. The Board is a projection: an
   ordinary exception out of it is recorded as a second line, with the
   exception as evidence, and changes neither the review outcome nor the
   retry already armed. Cancellation is not contained. *)
let announce_stall ~notify ~task_id ~verification_id ~cause ~disposition =
  Log.Misc.warn "%s" (stall_log_line ~task_id ~verification_id ~cause ~disposition);
  match
    notify
      ~task_id
      ~verification_id
      ~gate:(stalled_gate cause)
      ~detail:(stop_cause_detail cause)
      ~disposition
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Misc.error
      "system LLM completion authority stall notice did not reach the Board; the line above stands task_id=%s verification_id=%s error=%s"
      task_id
      verification_id
      (Printexc.to_string exn)
;;

(* Returns the control-flow outcome the scan loop acts on, paired with the
   observation outcome recorded for this review. [on_commit] is the exact
   semantic verdict produced by the evaluator. Infrastructure failures never
   call this function. A failed commit is its own outcome because the verdict
   was decided but never reached the Task. *)
type commit_apply_error =
  | Invalid_commit_intent of string
  | Workspace_commit_refused of Masc_domain.masc_error

let observe_original_change ~config ~original ~judgment ~authority change =
  let module P=Lane_addon_request_progress in
  let module AR=Task.Anti_rationalization in
  let task_id=(Verifier_review_original.review_request original).AR.task_id in
  let verification_id=Verifier_review_original.verification_id original in
  let decode change=Verifier_review_commit_intent.decode ~original ~judgment ~authority change in
  let* notes,started_at,_result,verdict=decode change in
  let* inspection=Workspace.read_task_inspection_r config ~task_id:task_id in
  match inspection with
  | Workspace.Inspected_task {task=current;location=_} ->
    let current_before=`Assoc ["task_id",`String current.id;
      "status",Masc_domain.task_status_to_yojson current.task_status] in
    if Yojson.Safe.equal current_before change.P.before then Ok current_before
    else
      let producer=(Verifier_review_original.review_request original).AR.agent_name in
      (* A rejection leaves the Task nonterminal and the producer then edits its
         handoff, so the handoff cannot prove the commit. The rejection relation
         the commit wrote to the backlog in the same step names this verification
         and does not depend on what the producer does afterwards. *)
      let* matched=match verdict,current.task_status with
        | AR.Approve _,Masc_domain.Done done_ -> Ok (done_.assignee=producer && done_.notes=Some notes)
        | AR.Reject reason,Masc_domain.InProgress work ->
          if not (work.assignee=producer && work.started_at=started_at) then Ok false
          else
            (match Workspace_task_rejection_outbox.standing config ~task_id ~verification_id
                     ~producer ~reason ~authority with
             | Ok Workspace_task_rejection_outbox.Current -> Ok true
             | Ok Obsolete -> Ok false
             | Error detail -> Error ("rejection relation unreadable: "^detail))
        | AR.Approve _,(Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _)
        | AR.Reject _,(Todo | Claimed _ | AwaitingVerification _ | Done _ | Cancelled _) -> Ok false in
      if matched then Ok change.after
      else Ok (`Assoc ["conflicting_task",Masc_domain.task_to_yojson current])
  | Task_unobserved -> Error "original commit Task is unobserved"
  | Task_deletion_recorded _ -> Error "original commit Task has deletion receipt"

let apply_original_change ~config ~original ~judgment ~authority change =
  let module W=Verifier_review_worker in
  let module AR=Task.Anti_rationalization in
  let task_id=(Verifier_review_original.review_request original).AR.task_id in
  let verification_id=Verifier_review_original.verification_id original in
  let decode change=Verifier_review_commit_intent.decode ~original ~judgment ~authority change in
  match decode change with
  | Error detail -> Error (W.Outcome_unknown {error=Invalid_commit_intent detail; detail})
  | Ok (notes,_started_at,result,review_verdict) ->
    match Workspace.commit_verdict_r config ~authority
      ~verdict:(completion_verdict_of_review review_verdict) ~task_id:task_id ~verification_id
      ~notes ~evaluator_runtime:result.AR.evaluator_runtime () with
    | Ok _ -> Ok ()
    | Error error ->
      let failure = Workspace_commit_refused error in
      let detail = Masc_domain.masc_error_to_string error in
      (match error with
       | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
         Error (W.Authority_refused {error=failure; detail})
       | Task (NotFound _ | AlreadyClaimed _ | NotClaimed _ | InvalidId _
           | TransitionRejected _ | VerificationSuperseded _)
       | Agent _ | Auth _ | System _ ->
         Error (W.Outcome_unknown {error=failure; detail}))

let commit_verdict_with_effects ~observe_original ~apply_original
      (config : Workspace_utils_backend_setup.config) (task : Masc_domain.task)
      ~store ~attempt ~installation_id ~package_id
      ~verification_id ~authority ~verdict:_ ~notes:_ ~verdict_label ~on_commit
      ~(evaluator_runtime : string option) =
  let module O = Verifier_review_owner in
  let module W = Verifier_review_worker in
  let module P = Lane_addon_request_progress in
  let module AR = Task.Anti_rationalization in
  let operation () =
    let* retained = O.load_retained ~store ~verification_id ~attempt ~installation_id ~package_id
      |> Result.map_error (function O.Not_found -> "original absent"
        | Load_store_unavailable d | Corrupt_original d -> d) in
    let original=O.original retained in
    let* judgment = match P.phase (O.progress retained) with
      | P.Judged json -> Ok json
      | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Ok commit.judgment
      | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
        Error "domain commit lacks original retained judgment" in
    let* before,_started_at =
      let status = match Lane_addon_request_progress.phase (O.progress retained) with
        | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
          (match commit.change.before with
           | `Assoc fields -> (match List.assoc_opt "status" fields with
               | Some json -> Masc_domain.task_status_of_yojson json
               | None -> Error "original commit before-state has no Task status")
           | _ -> Error "original commit before-state is malformed")
        | Judged _ -> Verifier_review_publication.captured_before retained
        | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
          Error "original review has no commit before-state" in
      let* status=status in
      match status with
      | Masc_domain.AwaitingVerification awaiting when awaiting.verification_id=verification_id
          && awaiting.assignee=(Verifier_review_original.review_request original).AR.agent_name ->
        Ok (`Assoc ["task_id",`String task.id;"status",Masc_domain.task_status_to_yojson status],awaiting.started_at)
      | Masc_domain.AwaitingVerification _ | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ ->
        Error "domain commit preparation differs from original verification" in
    let* captured_status=Verifier_review_publication.captured_before retained in
    let* captured=Verifier_review_commit_intent.before_of_status ~original captured_status in
    let* ()=if Yojson.Safe.equal before captured then Ok ()
      else Error "domain intent before-state differs from the captured original" in
    let* change=Verifier_review_commit_intent.prepare ~original ~judgment ~authority ~before in
    let after=change.P.after in
    let decode change = Verifier_review_commit_intent.decode
      ~original ~judgment ~authority change in
    let* ()=match P.phase (O.progress retained) with
      | Finished commit -> let* _=decode commit.change in Ok ()
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok () in
    let observe=observe_original ~config ~original ~judgment ~authority in
    let apply=apply_original ~config ~original ~judgment ~authority in
    match W.commit_attempt ~store ~verification_id ~attempt ~installation_id ~package_id
      ~change:{P.before;after} ~observe ~apply with
    | Ok () ->
      Log.Misc.info "system LLM completion authority confirmed task_id=%s verification_id=%s authority=%s verdict=%s"
        task.id verification_id (Masc_domain.completion_authority_actor authority) verdict_label;
      Ok (Committed,on_commit)
    | Error (W.Worker_error error) ->
      Error (match error with
        | W.Original_not_found -> "original absent"
        | Authority_unavailable detail | Original_corrupt detail | Grants_mismatch detail | Execution_pending detail | Execution_repair_required detail
        | Persistence_unavailable detail -> detail)
    | Error (W.Apply_failed (Invalid_commit_intent detail)) -> Error detail
    | Error (W.Apply_failed (Workspace_commit_refused error)) ->
      Error (Masc_domain.masc_error_to_string error)
    | Error (W.Commit_conflicted {commit; observed}) ->
      let* _ = decode commit.P.change in
      let* terminal_authority = Verifier_review_publication.terminal_authority_of_conflict ~task_id:task.id observed in
      Log.Misc.info
        "completion authority superseded task_id=%s verification_id=%s terminal=%s verdict=%s"
        task.id verification_id terminal_authority verdict_label;
      Ok (Superseded_by {authority=terminal_authority},
        Verification_run_registry.Superseded_by {authority=terminal_authority}) in
  match operation () with
  | Ok outcome -> outcome
  | Error detail ->
    let _ = evaluator_runtime in
    let cause=Commit_failed {detail} in Stalled cause,registry_outcome_of_stop_cause cause
;;

let commit_verdict_with_config = commit_verdict_with_effects
  ~observe_original:observe_original_change ~apply_original:apply_original_change

let commit_verdict (runtime:runtime) = commit_verdict_with_config runtime.config

(** What the system lane does with one Task it was woken for, read off the
    status alone. Pure, so the routing is testable without a runtime. *)
type admission =
  | Review_completion
  | Not_awaiting

let admission_of_status = function
  | Masc_domain.AwaitingVerification _ -> Review_completion
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> Not_awaiting
;;

exception Retained_review_failed of exn

let with_retained_publication fn =
  match fn () with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise (Retained_review_failed exn)
  | exception exn -> raise (Retained_review_failed exn)

let with_original_publication_guard ~store ~verification_id ~attempt ~installation_id ~package_id fn =
  match fn () with
  | value -> value
  | exception exn ->
    let preserve =
      match Eio.Cancel.protect (fun () -> Verifier_review_owner.load_retained
        ~store ~verification_id ~attempt ~installation_id ~package_id) with
      | Ok retained ->
        (match (Lane_addon_request_progress.observer
          (Verifier_review_owner.progress retained)).registration with
         | Lane_addon_request_receipt.Unobserved -> false
         | Pending _ | Acknowledged _ -> true)
      | Error _ -> true
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
        raise (Retained_review_failed cancelled)
      | exception _ -> true in
    if preserve then raise (Retained_review_failed exn) else raise exn

let preserve_original_publication ~store ~verification_id ~task_id ~producer =
  match Eio.Cancel.protect (fun () -> Verifier_review_owner.pending_commits
    ~selection:(Verifier_review_owner.Verification verification_id)
    ~terminal_pending:Verifier_review_publication.needs_publication ~store
    ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review") with
  | Error _ -> true
  | Ok pending -> List.exists (fun retained ->
      let original=Verifier_review_owner.original retained in
      let request=Verifier_review_original.review_request original in
      Verifier_review_original.verification_id original=verification_id
        && request.Task.Anti_rationalization.task_id=task_id && request.agent_name=producer
        && (match (Lane_addon_request_progress.observer
          (Verifier_review_owner.progress retained)).registration with
          | Lane_addon_request_receipt.Unobserved -> false
          | Pending _ | Acknowledged _ -> true)) pending
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise (Retained_review_failed exn)
  | exception _ -> true

let unless_original_publication ~store ~verification_id ~task_id ~producer ~otherwise =
  if preserve_original_publication ~store ~verification_id ~task_id ~producer then false
  else (otherwise (); true)

let process_task_once ?(registry=Verification_run_registry.global ())
      (runtime : runtime)
      (task : Masc_domain.task)
      ~assignee
      ~verification_id
  =
  let authority = system_authority in
  (* Retained publication resumes its original lifecycle without registering a
     new Running row or substituting this recovery wake's clocks/tools. *)
  let started_at = Eio.Time.now runtime.clock in
  let tools = ref [] in
  let on_tool_result ~input result =
    tools :=
      Verification_run_registry.observe_tool_result
        ~input
        ~finished_at:(Eio.Time.now runtime.clock)
        result
      :: !tools
  in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir runtime.config) "lane-addons") in
  let complete ?evaluator_runtime (process_outcome, outcome) =
    Verification_run_registry.mark_completed
      registry
      ~verification_id
      ~outcome
      ~tools:(List.rev !tools)
      ?evaluator_runtime
      ~elapsed_s:(Eio.Time.now runtime.clock -. started_at)
      ();
    process_outcome
  in
  let complete_retained ~store ~retained (process_outcome,outcome) =
    let original=Verifier_review_owner.original retained in
    match Verifier_review_owner.load_retained ~store ~verification_id
      ~attempt:(Verifier_review_original.attempt original)
      ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review" with
    | Error _ -> Stalled (Commit_failed {detail="terminal review owner readback unavailable"})
    | Ok retained ->
      (match Lane_addon_request_progress.phase (Verifier_review_owner.progress retained) with
       | Finished _ | Conflicted _ ->
         (match Verifier_review_publication.publish_terminal ~store ~registry ~retained ~outcome with
          | Ok () -> process_outcome
          | Error detail -> Stalled (Commit_failed {detail}))
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
       | Commit_unknown _ | Rejected _ | Subdividing _ | Subdivided _ ->
         (* The exact retained commit is unresolved; do not overwrite its
            immutable observation with a competing registry completion. *)
         process_outcome)
  in
  let stop cause =
    ignore (unless_original_publication ~store ~verification_id ~task_id:task.id ~producer:assignee
      ~otherwise:(fun () -> ignore (complete (Stalled cause,registry_outcome_of_stop_cause cause))));
    Stalled cause in
  let defer_unavailable ~stage ~detail = stop (Infrastructure_unavailable { stage; detail }) in
  try
    match Verifier_review_owner.retained_commits ~store
      ~selection:(Verifier_review_owner.Verification verification_id)
      ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review" with
    | Error _ -> defer_unavailable ~stage:Verification_run_registry.Review_preparation
        ~detail:"original host judgment inventory unavailable"
    | Ok pending ->
      match List.find_opt (fun retained ->
        let original=Verifier_review_owner.original retained in
        Verifier_review_original.verification_id original=verification_id
          && (Verifier_review_original.review_request original).task_id=task.id
          && (Verifier_review_original.review_request original).agent_name=assignee) pending with
      | Some retained -> with_retained_publication (fun () ->
        let stop cause=Stalled cause in
        let original=Verifier_review_owner.original retained in
        let judgment=match Lane_addon_request_progress.phase (Verifier_review_owner.progress retained) with
          | Judged judgment -> Some judgment
          | Committing commit | Commit_unknown (commit,_) | Finished commit
          | Conflicted (commit,_) -> Some commit.judgment
          | Captured | Admission_wait _ | Dispatch_pending _
          | Rejected _ | Subdividing _ | Subdivided _ -> None in
        (match judgment with
         | None -> stop (Raised {detail="retained host judgment changed during recovery"})
         | Some judgment ->
           (match Verifier_review_owner.judgment_of_json ~original judgment with
            | Error detail -> stop (Raised {detail})
            | Ok (result,notes) -> (match result.Task.Anti_rationalization.verdict with
                | None -> stop (Raised {detail="original host judgment has no structured verdict"})
                | Some review_verdict ->
                  let on_commit=match review_verdict with
                    | Approve reason -> Verification_run_registry.Approved {reason}
                    | Reject reason -> Verification_run_registry.Rejected {reason} in
                  complete_retained ~store ~retained
                    (commit_verdict runtime task ~store ~attempt:(Verifier_review_original.attempt original)
                      ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review"
                      ~verification_id ~authority ~verdict:(completion_verdict_of_review review_verdict)
                      ~notes ~verdict_label:(Task.Anti_rationalization.verdict_constructor_name review_verdict)
                      ~on_commit ~evaluator_runtime:(Some result.evaluator_runtime))))))
      | None ->
      match admission_of_status task.task_status with
      | Not_awaiting -> Stalled (Infrastructure_unavailable {
          stage=Verification_run_registry.Review_preparation;
          detail="Task is not awaiting this verification and has no retained host judgment"})
    | Review_completion ->
  Verification_run_registry.register_running
    registry
    ~verification_id
    ~task_id:task.id
    ~producer:assignee
    ~authority_kind:(Masc_domain.completion_authority_kind authority)
    ~authority_actor:(Masc_domain.completion_authority_actor authority)
    ~started_at;
    match
      prepare_review
        ~config:runtime.config
        ~task
        ~assignee
        ~verification_id
        ~authority
    with
    | Error reason ->
      defer_unavailable
        ~stage:Verification_run_registry.Review_preparation
        ~detail:reason
    | Ok prepared ->
      (let lookup_authority = Eio.Lazy.from_fun ~cancel:`Record (fun () -> Verification_authority_tools.create_task_review
         ~config:runtime.config ~verification_id ~task_id:task.id ~producer:assignee
         ~evidence_access:prepared.evidence_access) in
       let prepare_authority () = Eio.Lazy.force lookup_authority in
            (* Human labels close the judge's own loop: where an operator
               disagreed with a past verdict, the divergence returns to the
               judge as a few-shot example, false positives first. Filled
               here, where the ledger and the snapshot are read, so the
               question picker stays a pure mapping. *)
            let question =
              { prepared.question with
                Task.Anti_rationalization.few_shot_block =
                  Eval_calibration.format_few_shot_block
                    (Eval_calibration.select_examples
                       ~max_examples:judge_few_shot_examples)
              ; evidence_posture =
                  evidence_posture_of_snapshot prepared.evidence_access
              }
            in
            (* E06: retain the immutable original of this review attempt, then
               hand the review to the worker bridge. The original freezes the
               subject and the lookup grants; the worker can only answer the
               review, never widen the subject or reapply another
               verification's evidence. The verdict extraction, verdict tool
               and Task/Goal transition stay on this host side below. *)
            let owner_store =
              Lane_addon_store.create
                ~root:(Filename.concat (Workspace.masc_dir runtime.config) "lane-addons")
            in
            let installation_id = "masc.completion-authority" in
            let package_id = "masc.completion-authority.review" in
            let prepared_original : (int * Verifier_review_original.t, Verifier_review_worker.error) result =
              let* attempt =
                Verifier_review_owner.next_attempt ~store:owner_store ~verification_id
                  ~installation_id ~package_id
                |> Result.map_error (function
                  | Verifier_review_owner.Not_found -> Verifier_review_worker.Original_not_found
                  | Verifier_review_owner.Load_store_unavailable d -> Verifier_review_worker.Persistence_unavailable d
                  | Verifier_review_owner.Corrupt_original d -> Verifier_review_worker.Original_corrupt d) in
              let* () = match Verifier_review_owner.load_for_destination ~store:owner_store
                ~verification_id ~attempt ~installation_id ~package_id with
              | Ok _ -> Ok ()
              | Error (Verifier_review_owner.Load_store_unavailable detail) -> Error (Verifier_review_worker.Persistence_unavailable detail)
              | Error (Verifier_review_owner.Corrupt_original detail) -> Error (Verifier_review_worker.Original_corrupt detail)
              | Error Verifier_review_owner.Not_found ->
              let* lookup_authority = prepare_authority ()
                |> Result.map_error (fun detail -> Verifier_review_worker.Authority_unavailable detail) in
              let lookup_tools = Verification_authority_tools.task_review_tools lookup_authority in
              let lookup_root = Verification_authority_tools.task_review_root lookup_authority in
              let* original =
                Verifier_review_original.prepare
                  ~generator_runtime:(Option.map
                    (fun identity -> identity.Runtime_response_identity.runtime_id) prepared.producer_execution)
                  ~verification_id
                  ~attempt
                  ~question
                  ~lookup_root
                  ~lookup_binding:(Verification_authority_tools.task_review_binding lookup_authority)
                  ~lookup_schemas:(List.map (fun (s : Types_core.tool_schema) -> s.name)
                                     (Verification_authority_tools.schemas lookup_tools))
                  prepared.review_request
                |> Result.map_error (fun reason -> Verifier_review_worker.Original_corrupt reason)
              in
              Verifier_review_owner.retain
                  ~store:owner_store
                  ~verification_id
                  ~attempt
                  ~installation_id
                  ~package_id
                  original
                |> Result.map_error (function
                  | Verifier_review_owner.Original_invalid d -> Verifier_review_worker.Original_corrupt d
                  | Verifier_review_owner.Identity_mismatch d -> Verifier_review_worker.Original_corrupt d
                  | Verifier_review_owner.Retain_store_unavailable d -> Verifier_review_worker.Persistence_unavailable d
                  | Verifier_review_owner.Already_retained d -> Verifier_review_worker.Original_corrupt d)
              in
              let* original=Verifier_review_owner.load_for_destination ~store:owner_store
                ~verification_id ~attempt ~installation_id ~package_id
                |> Result.map_error (function Verifier_review_owner.Not_found -> Verifier_review_worker.Original_not_found
                  | Load_store_unavailable detail -> Verifier_review_worker.Persistence_unavailable detail
                  | Corrupt_original detail -> Verifier_review_worker.Original_corrupt detail) in
              Ok (attempt,original)
            in
            let run_result =
              let* attempt,original = prepared_original in
              let* reviewed_original,result =
              with_original_publication_guard ~store:owner_store ~verification_id ~attempt
                ~installation_id ~package_id (fun () -> Verifier_review_worker.run_attempt
                ~prepare_observer_registration:(fun result ->
                  let* outcome=match result.Task.Anti_rationalization.verdict with
                    | Some (Approve reason) -> Ok (Verification_run_registry.Approved {reason})
                    | Some (Reject reason) -> Ok (Verification_run_registry.Rejected {reason})
                    | None -> Error "observer registration requires a retained verdict" in
                  let expected : Verification_run_registry.run = {
                    verification_id;task_id=task.id;producer=assignee;
                    authority_kind=Masc_domain.completion_authority_kind authority;
                    authority_actor=Masc_domain.completion_authority_actor authority;
                    started_at;status=Verification_run_registry.Completed {outcome;
                      evaluator_runtime=Some result.evaluator_runtime;tools=List.rev !tools;
                      elapsed_s=Eio.Time.now runtime.clock -. started_at}} in
                  Verifier_review_publication.execution_receipt ~original ~result ~before:task.task_status ~expected)
                ~prepare_notes:(fun result -> review_notes ~request:prepared.request
                  ~evidence_access:prepared.evidence_access ~unread_images:prepared.unread_images ~result ~authority)
                ~on_tool_result
                ~sw:(Some runtime.sw)
                ~store:owner_store
                ~verification_id
                ~attempt
                ~installation_id
                ~package_id
                ~base_path:runtime.config.base_path ~prepare_authority
                ~provider_rest:Verification_retry.provider_rest
                ())
              in Ok (attempt,reviewed_original,result)
            in
            match run_result with
            | Error (Verifier_review_worker.Execution_pending detail) -> stop (Execution_pending {detail})
            | Error (Verifier_review_worker.Execution_repair_required detail) -> stop (Execution_repair_required {detail})
            | Error (Verifier_review_worker.Authority_unavailable detail) ->
              defer_unavailable ~stage:Verification_run_registry.Lookup_surface ~detail
            | Error (Verifier_review_worker.Persistence_unavailable detail) ->
              defer_unavailable ~stage:Verification_run_registry.Review_preparation ~detail
            | Error Verifier_review_worker.Original_not_found -> stop (Raised {detail="verifier original not found"})
            | Error (Verifier_review_worker.Original_corrupt detail | Grants_mismatch detail) -> stop (Raised {detail})
            | Ok (attempt,original,result) ->
            (* Every verdict lands in the calibration ledger the Harness
               surface reads — which evaluator judged, and whether a fallback
               answered for the intended one. The judge kept running after the
               July evaluation flow was removed, but this call went with it,
               and the ledger starved for a month while verdicts flowed
               (last record 2026-07-27; the surface read as a museum). A
               non-verdict is a no-op inside; the stalled path below already
               reaches the Board. *)
            let reviewed_request = Verifier_review_original.review_request original in
            (* The v3 original freezes the generator runtime, not the submitting
               response identity. The current wake cannot bind that identity to
               this original, even when both name the same runtime. *)
            Eval_calibration.record_verdict ~task_id:reviewed_request.task_id
              ~req:reviewed_request ~result ();
            let evaluator_runtime = result.evaluator_runtime in
            match result.verdict with
       | None ->
         let cause = not_reviewed_of_result result in
         complete ~evaluator_runtime (Stalled cause, registry_outcome_of_stop_cause cause)
       | Some review_verdict ->
         let verdict = completion_verdict_of_review review_verdict in
         let notes =
           review_notes
             ~request:prepared.request
             ~evidence_access:prepared.evidence_access
             ~unread_images:prepared.unread_images
             ~result
             ~authority
         in
         (* Built from [review_verdict], not from [verdict]: the domain verdict
            drops the reason on approval, and the registry row is where an
            operator later asks what the reviewer checked. *)
         let on_commit =
           match review_verdict with
           | Task.Anti_rationalization.Approve reason ->
             Verification_run_registry.Approved { reason }
           | Task.Anti_rationalization.Reject reason ->
             Verification_run_registry.Rejected { reason }
         in
         let publication = Verifier_review_owner.load_retained ~store:owner_store ~verification_id
           ~attempt ~installation_id ~package_id in
         (match publication with
          | Error _ -> Stalled (Commit_failed {detail="retained review readback unavailable"})
          | Ok retained -> with_retained_publication (fun () ->
            complete_retained ~store:owner_store ~retained
              (commit_verdict runtime task
                ~store:owner_store ~attempt ~installation_id ~package_id
                ~verification_id ~authority ~verdict ~notes
                ~verdict_label:(Task.Anti_rationalization.verdict_constructor_name review_verdict)
                ~on_commit ~evaluator_runtime:(Some evaluator_runtime)))))
  with
  | Retained_review_failed (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | Retained_review_failed exn -> Stalled (Raised {detail=Printexc.to_string exn})
  | Eio.Cancel.Cancelled _ as exn ->
    (* Mirror the four exact lanes: a cancelled review completes its
       observation row before the cancellation continues, so it neither
       stays Running in memory nor vanishes on the next replay (lane audit
       W6 — a cancelled verifier run used to leave no trace at all). The
       Task obligation remains; the boot sweep restores its exact retained
       execution/commit state and never assumes cancellation means no dispatch. *)
    Eio.Cancel.protect (fun () ->
      ignore (unless_original_publication ~store ~verification_id ~task_id:task.id ~producer:assignee
        ~otherwise:(fun () -> complete
          ( (), Verification_run_registry.Review_cancelled
              {detail="review fiber cancelled: " ^ Printexc.to_string exn}))));
    raise exn
  | exn -> stop (Raised { detail = Printexc.to_string exn })
;;

(* Boot and a failed backlog read have no key to aim at. Everything else does,
   and must use [request_review] instead. *)
let request_sweep (runtime : runtime) =
  Atomic.set runtime.sweep_pending true;
  Eio.Condition.broadcast runtime.wake
;;

let request_review (runtime : runtime) key =
  let rec loop () =
    let current = Atomic.get runtime.targets in
    if List.exists (review_key_equal key) current
    then ()
    else if Atomic.compare_and_set runtime.targets current (key :: current)
    then ()
    else loop ()
  in
  loop ();
  Eio.Condition.broadcast runtime.wake
;;

let queue_retry ~sw ~wait ~dispatch pending scope =
  Eio.Switch.check sw;
  let rec enqueue () =
    let current = Atomic.get pending in
    let batch =
      match current with
      | None -> { keys = Review_keys.empty; sweep = false }
      | Some batch -> batch
    in
    let next =
      match scope with
      | Whole_backlog -> { batch with sweep = true }
      | Targets keys ->
        { batch with
          keys = List.fold_left (fun set key -> Review_keys.add key set) batch.keys keys
        }
    in
    if batch.sweep = next.sweep && Review_keys.equal batch.keys next.keys
    then Already_pending
    else if Atomic.compare_and_set pending current (Some next)
    then (
      match current with
      | Some _ -> Joined_running_timer
      | None ->
        (* A daemon, because nothing waits for this timer and the switch must
           not either: it only accelerates the next attempt at an obligation
           the backlog already holds. As an ordinary fiber it kept a normally
           returning [Switch.run] waiting out the whole interval. *)
        Eio.Fiber.fork_daemon ~sw (fun () ->
           wait ();
           (* Detach the entire batch before publication. A retry arriving
              during dispatch owns the next timer and cannot be cleared by
              this one. A cancelled timer leaves the durable awaiting Tasks
              for the next runtime's boot sweep. *)
          (match Atomic.exchange pending None with
           | None -> ()
           | Some { keys; sweep } ->
             dispatch
               (if sweep then Whole_backlog else Targets (Review_keys.elements keys)));
          `Stop_daemon);
        Armed_timer)
    else enqueue ()
  in
  enqueue ()
;;

let schedule_retry_scope (runtime : runtime) ~delay_sec scope =
  queue_retry
    ~sw:runtime.sw
    ~wait:(fun () -> Eio.Time.sleep runtime.clock delay_sec)
    ~dispatch:(function
      | Whole_backlog -> request_sweep runtime
      | Targets keys -> List.iter (request_review runtime) keys)
    runtime.retry_pending
    scope
;;

(* Retry when the first candidate whose failure passes with time can serve
   again: at the pulse when one already serves, or when the earliest recorded
   path rest ends (a provider's stated rate-limit or quota reset). The last
   diagnostic may name a different, long-resting slot. *)
let retry_delay_sec ~retry_interval_sec ~now = function
  | Not_reviewed { retryable_runtimes; _ } ->
    Verification_retry.delay ~retry_interval_sec ~now retryable_runtimes
  | Execution_pending _ | Execution_repair_required _ | Infrastructure_unavailable _ | Commit_failed _ | Raised _ -> retry_interval_sec
;;

(* A retry that only waits the pulse joins the shared timer. One that must
   wait out a resting slot arms its own: joining the shared timer would fire
   it at the pulse, inside the rest, and arming the shared timer with the
   rest would hold back every serving key and sweep that joins after it. A
   key reviewed twice is still one review at a time ([claim_review]). *)
let schedule_retry (runtime : runtime) key ~delay_sec =
  if Float.compare delay_sec runtime.retry_interval_sec > 0
  then (
    Eio.Switch.check runtime.sw;
    Eio.Fiber.fork_daemon ~sw:runtime.sw (fun () ->
      Eio.Time.sleep runtime.clock delay_sec;
      request_review runtime key;
      `Stop_daemon);
    Armed_timer)
  else schedule_retry_scope runtime ~delay_sec (Targets [ key ])
;;

let schedule_sweep_retry (runtime : runtime) =
  (* The backlog-read diagnostic already names this request. A duplicate
     sweep shares the existing timer and needs no separate notification. *)
  let (_ : retry_admission) =
    schedule_retry_scope runtime ~delay_sec:runtime.retry_interval_sec Whole_backlog
  in
  ()
;;

let process_task (runtime : runtime) (task : Masc_domain.task) ~assignee ~verification_id =
  let key = { task_id = task.id; verification_id } in
  if claim_review runtime key
  then (
    (* An evaluator failure that passes with time -- a transient error, or a
       path resting until a time its provider stated -- has no producer
       action that can legally advance the Task: it is still
       [AwaitingVerification]. Re-arm the application-owned scan after the
       durable run observation is recorded, then say what the scheduler did —
       in the log first, then on the Board. Every other stall keeps the
       producer/operator contract, and restart recovery still comes from
       [start]'s initial pending scan. *)
    let outcome : process_outcome =
      Fun.protect
        ~finally:(fun () -> release_review runtime key)
        (fun () -> process_task_once runtime task ~assignee ~verification_id)
    in
    match outcome with
    | Committed | Superseded_by _ -> ()
    | Stalled cause ->
      (* A key requests a retry whenever one candidate's failure passes with
         time, and a provider rest dates that retry at the rest's end rather
         than stopping it. A key that requests none had only failures time
         does not change -- a credential, a configuration, a refused request,
         an account refusal or a quota with no stated end -- and nothing
         schedules another look at it: the scope rule admits it again only
         through a fresh submission, or through the sweep, which is armed at
         boot and after a failed backlog read rather than on a timer. So that
         Task sits in [AwaitingVerification] until a producer or operator
         acts, and the registry row alone reaches no one: every stop is
         promoted to the Board, where the producer Keeper and the operator
         read it and decide whether to resubmit. *)
      let delay_sec =
        retry_delay_sec
          ~retry_interval_sec:runtime.retry_interval_sec
          ~now:(Eio.Time.now runtime.clock)
          cause
      in
      let scheduling =
        match retry_request_of_stop_cause cause with
        | No_retry_requested -> Retry_not_requested
        | Retry_requested | Observe_original_requested -> Retry_admitted (schedule_retry runtime key ~delay_sec)
      in
      (* One disposition, read after the scheduler answered, drives both the
         WARN template and the Board sentence: the reader of either is told
         about a timer that exists. Visibility only; the Board schedules
         nothing. *)
      announce_stall
        ~notify:(fun ~task_id ~verification_id ~gate ~detail ~disposition ->
          let evaluator_runtime =
            match cause with
            | Not_reviewed { evaluator_runtime; _ } -> Some evaluator_runtime
            | Execution_pending _ | Execution_repair_required _ | Infrastructure_unavailable _ | Commit_failed _ | Raised _ -> None
          in
          Verification_protocol.notify_stalled_verification_with_runtime
            ~authority:system_authority
            ~subject:
              (Verification_protocol.Task_review
                 { task_id; verification_id; disposition })
            ~gate
            ~detail
            ~evaluator_runtime)
        ~task_id:task.id
        ~verification_id
        ~cause
        ~disposition:
          (let disposition = stall_disposition_of_scheduling ~retry_interval_sec:delay_sec scheduling in
           match cause with
           | Execution_pending _ ->
             (match disposition with
              | Verification_protocol.Retry_scheduled {delay} ->
                Verification_protocol.Original_observation_scheduled {delay}
              | Original_observation_scheduled _ | Original_repair_required | No_retry_armed -> disposition)
           | Execution_repair_required _ -> Verification_protocol.Original_repair_required
           | Infrastructure_unavailable _ | Commit_failed _ | Not_reviewed _ | Raised _ -> disposition))
  else
    Log.Misc.debug
      "system LLM completion authority skipped duplicate in-flight review task_id=%s verification_id=%s"
      task.id
      verification_id
;;

let recover_terminal_publications (runtime:runtime) ~registry ~scope =
  let module O=Verifier_review_owner in
  let module V=Verifier_review_original in
  let module P=Lane_addon_request_progress in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir runtime.config) "lane-addons") in
  let* pending=O.pending_commits ~terminal_pending:Verifier_review_publication.needs_publication
    ~selection:O.All_verifications
    ~store ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review"
    |> Result.map_error (function O.Not_found -> "review publication inventory absent"
      | Load_store_unavailable detail | Corrupt_original detail -> detail) in
  let terminal=List.filter_map (fun retained -> match P.phase (O.progress retained) with
    | Finished _ | Conflicted _ ->
      let original=O.original retained in
      Some ({task_id=(V.review_request original).Task.Anti_rationalization.task_id;
        verification_id=V.verification_id original},retained)
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
    | Commit_unknown _ | Rejected _ | Subdividing _ | Subdivided _ -> None) pending in
  let count,failures=List.fold_left (fun (count,failures) (key,retained) ->
    if not (claim_review runtime key) then count,failures else
    let result=Fun.protect ~finally:(fun () -> release_review runtime key) (fun () ->
      Verifier_review_publication.recover_terminal ~store ~registry ~retained) in
    match result with
    | Ok _ -> count+1,failures
    | Error detail -> count,(key.verification_id ^ ": " ^ detail)::failures)
    (0,[]) (entries_in_scope ~scope terminal) in
  Ok (count,List.rev failures)
;;

let process_scope (runtime : runtime) ~scope =
  (match recover_terminal_publications runtime ~registry:(Verification_run_registry.global ()) ~scope with
   | Ok (_,failures) -> List.iter (fun detail ->
       Log.Misc.error "retained Task publication recovery unavailable: %s" detail) failures
   | Error detail -> Log.Misc.error "retained Task publication inventory unavailable: %s" detail);
  match Workspace_backlog.read_backlog_r runtime.config with
  | Error detail ->
    Log.Misc.error
      "system LLM completion authority backlog read failed; pending tasks remain unresolved: %s"
      detail;
    (* The read failed, so which keys are awaiting is unknown. Re-read the whole
       backlog rather than guess. *)
    schedule_sweep_retry runtime
  | Ok backlog ->
    let entries =
      List.filter_map
        (fun (task : Masc_domain.task) ->
           match task.task_status with
           | Masc_domain.AwaitingVerification { assignee; verification_id; _ } ->
             Some ({ task_id = task.id; verification_id }, (task, assignee))
           | Masc_domain.Todo
           | Masc_domain.Claimed _
           | Masc_domain.InProgress _
           | Masc_domain.Done _
           | Masc_domain.Cancelled _ -> None)
        backlog.tasks
    in
    let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir runtime.config) "lane-addons") in
    let entries = match Verifier_review_owner.pending_commits
      ~selection:Verifier_review_owner.All_verifications
      ~terminal_pending:Verifier_review_publication.needs_publication ~store
      ~installation_id:"masc.completion-authority" ~package_id:"masc.completion-authority.review" with
      | Error _ ->
        Log.Misc.error "verifier original commit inventory unavailable; no commit recovery inferred";
        entries
      | Ok pending -> List.fold_left (fun entries retained ->
          let original=Verifier_review_owner.original retained in
          let req=Verifier_review_original.review_request original in
          let key={task_id=req.task_id;verification_id=Verifier_review_original.verification_id original} in
          if List.exists (fun (present,_) -> review_key_equal present key) entries then entries
          else match Lane_addon_request_progress.phase (Verifier_review_owner.progress retained) with
            | Finished _ | Conflicted _ -> entries
            | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
            | Commit_unknown _ | Rejected _ | Subdividing _ | Subdivided _ ->
            match Workspace.read_task_inspection_r runtime.config ~task_id:req.task_id with
            | Ok (Workspace.Inspected_task {task;location=_}) -> (key,(task,req.agent_name))::entries
            | Error detail ->
              Log.Misc.error "verifier pending commit Task observation unavailable: %s" detail; entries
            | Ok (Task_unobserved | Task_deletion_recorded _) -> entries) entries pending in
    List.iter
      (fun (key, (task, assignee)) ->
         Eio.Fiber.fork ~sw:runtime.sw (fun () ->
           Eio.Semaphore.acquire runtime.review_slots;
           (* fun-protect-finally-ok: [Eio.Semaphore.release] is
              non-suspending and must return the bounded review slot on
              normal completion, exception, or cancellation. *)
           Fun.protect
             ~finally:(fun () -> Eio.Semaphore.release runtime.review_slots)
             (fun () ->
                process_task runtime task ~assignee ~verification_id:key.verification_id)))
      (entries_in_scope ~scope entries)
;;

let request_rejection_delivery (runtime : runtime) =
  Atomic.set runtime.rejection_delivery_pending true;
  Eio.Condition.broadcast runtime.wake
;;

let retry_rejection_delivery (runtime : runtime) =
  if Atomic.compare_and_set runtime.rejection_retry_pending false true then
    (* Same reason as the review timer: the retry is an accelerator, and the
       reconcile backlog is the durable obligation. Nothing joins it. *)
    Eio.Fiber.fork_daemon ~sw:runtime.sw (fun () ->
      Eio.Time.sleep runtime.clock runtime.retry_interval_sec;
      Atomic.set runtime.rejection_retry_pending false;
      request_rejection_delivery runtime;
      `Stop_daemon)
;;

let process_rejection_deliveries (runtime : runtime) =
  (* Separate from review scopes: retrying a delivery must never run another
     model judgment over an already-settled verdict. The backlog is the durable
     obligation and this timer only accelerates the next attempt. *)
  match Completion_authority_wakeup.reconcile_pending ~config:runtime.config with
  | Ok { retained = 0; _ } -> ()
  | Ok _ -> retry_rejection_delivery runtime
  | Error detail ->
    Log.Misc.error "completion repair backlog unavailable: %s" detail;
    retry_rejection_delivery runtime
;;

let run (runtime : runtime) : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    (* Targets first: a named verification is the common case and costs one
       backlog read for the batch that accumulated since the last wake. The
       sweep stays for boot and for a failed read, which have no key to aim at. *)
    (match take_targets runtime with
     | [] -> ()
     | (_ :: _) as keys -> process_scope runtime ~scope:(Targets keys));
    if Atomic.exchange runtime.sweep_pending false
    then process_scope runtime ~scope:Whole_backlog;
    if Atomic.exchange runtime.rejection_delivery_pending false
    then process_rejection_deliveries runtime;
    None)
;;

let install_callback (runtime : runtime) =
  Atomic.set Workspace_hooks.rejection_delivery_requested_fn (fun config ->
    if String.equal config.Workspace.base_path runtime.config.base_path
    then request_rejection_delivery runtime
    else Log.Misc.error "completion repair rejected wake from another base path");
  Atomic.set Workspace_hooks.verification_submitted_fn
    (fun config ~task ~assignee ~verification_id ->
       if not (String.equal config.base_path runtime.config.base_path)
       then
         Log.Misc.error
           "system LLM completion authority rejected submit from another base path task_id=%s verification_id=%s"
           task.id
           verification_id
       else if String.equal (String.trim verification_id) ""
       then
         Log.Misc.error
           "system LLM completion authority rejected empty verification id task_id=%s"
           task.id
       else (
         request_review runtime { task_id = task.id; verification_id };
         Log.Misc.info
           "system LLM completion authority scheduled task_id=%s verification_id=%s producer=%s"
           task.id
           verification_id
           assignee))
;;

let make_runtime ~sw ~clock ~(config:Workspace_utils_backend_setup.config) =
    { config
    ; sw
    ; clock
    ; wake = Eio.Condition.create ()
    ; sweep_pending = Atomic.make true
    ; rejection_delivery_pending = Atomic.make true
    ; rejection_retry_pending = Atomic.make false
    ; targets = Atomic.make []
    ; retry_pending = Atomic.make None
    ; retry_interval_sec = Env_config.Timeouts.maintenance_pulse_interval_sec
    ; in_flight = Atomic.make []
    ; review_slots = Eio.Semaphore.make 4
    }

;;

let start ~sw ~clock ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime=make_runtime ~sw ~clock ~config in
  let owner = Some runtime in
  match Atomic.compare_and_set active_runtime None owner with
  | false ->
    (match Atomic.get active_runtime with
     | Some active when String.equal active.config.base_path config.base_path ->
       Log.Misc.warn
         "system LLM completion authority already started for base path %s"
         config.base_path
     | Some active ->
       Log.Misc.error
         "system LLM completion authority already owns base path %s; refusing second base path %s"
         active.config.base_path
         config.base_path
     | None ->
       (* A concurrent starter won the CAS between the failed read and this
          branch. The next bootstrap owns the diagnostic; no duplicate lane is
          created here. *)
       Log.Misc.error
         "system LLM completion authority start race left no visible owner")
  | true ->
    let previous_submitted_hook =
      Atomic.get Workspace_hooks.verification_submitted_fn
    in
    let previous_rejection_hook =
      Atomic.get Workspace_hooks.rejection_delivery_requested_fn
    in
    install_callback runtime;
    Eio.Switch.on_release sw (fun () ->
      if Atomic.compare_and_set active_runtime owner None
      then (
        Atomic.set Workspace_hooks.verification_submitted_fn previous_submitted_hook;
        Atomic.set Workspace_hooks.rejection_delivery_requested_fn previous_rejection_hook));
    Eio.Fiber.fork_daemon ~sw (fun () -> run runtime)
;;

module For_testing = struct
  let unless_original_publication = unless_original_publication
  type nonrec commit_apply_error = commit_apply_error =
    | Invalid_commit_intent of string
    | Workspace_commit_refused of Masc_domain.masc_error
  let observe_original = observe_original_change
  let apply_original = apply_original_change

  let recover_original_publications ~registry ~config ~sw ~clock =
    let runtime=make_runtime ~config ~sw ~clock in
    recover_terminal_publications runtime ~registry ~scope:Whole_backlog

  let process_original_once ~registry ~config ~sw ~clock ~task ~assignee ~verification_id =
    let runtime=make_runtime ~config ~sw ~clock in
    match process_task_once ~registry runtime task ~assignee ~verification_id with
    | Committed -> Ok ()
    | Superseded_by {authority} -> Error ("original superseded by " ^ authority)
    | Stalled cause -> Error (stop_cause_detail cause)

  let commit_original_with_effects ~observe ~apply ~config ~task ~store ~attempt ~installation_id ~package_id ~verification_id ~notes =
    match commit_verdict_with_effects ~observe_original:observe ~apply_original:apply
      config task ~store ~attempt ~installation_id ~package_id
      ~verification_id ~authority:system_authority ~verdict:Masc_domain.Verdict_approved
      ~notes ~verdict_label:"retained" ~on_commit:(Verification_run_registry.Approved {reason="retained"})
      ~evaluator_runtime:None with
    | Committed,_ -> Ok ()
    | Superseded_by {authority},_ -> Error ("original superseded by " ^ authority)
    | Stalled cause,_ -> Error (stop_cause_detail cause)

  let commit_original = commit_original_with_effects
    ~observe:observe_original_change ~apply:apply_original_change

  let authority_actor = authority_actor
  let retry_delay_of_paths = Verification_retry.delay_of_paths
  let evidence_refs_of_output = evidence_refs_of_output
  let verdict_question_of_request = verdict_question_of_request
  let completion_verdict_of_review = completion_verdict_of_review
  let review_notes = review_notes

  type nonrec evidence_images = evidence_images =
    { images : Task.Anti_rationalization.evidence_image list
    ; unread : (string * Workspace_verification_store.read_binary_error) list
    }

  let evidence_images_of_snapshot = evidence_images_of_snapshot

  type nonrec retry_request = retry_request =
    | Retry_requested
    | Observe_original_requested
    | No_retry_requested

  type nonrec retry_admission = retry_admission =
    | Armed_timer
    | Joined_running_timer
    | Already_pending

  type nonrec retry_scheduling = retry_scheduling =
    | Retry_not_requested
    | Retry_admitted of retry_admission

  type nonrec stop_cause = stop_cause =
    | Infrastructure_unavailable of
        { stage : Verification_run_registry.infrastructure_stage
        ; detail : string
        }
    | Commit_failed of { detail : string }
    | Not_reviewed of
        { gate : string
        ; detail : string
        ; evaluator_runtime : string
        ; retryable_runtimes : string list
        ; model_absent_runtimes : string list
        }
    | Execution_pending of { detail : string }
    | Execution_repair_required of { detail : string }
    | Raised of { detail : string }

  type nonrec process_outcome = process_outcome =
    | Committed
    | Superseded_by of { authority : string }
    | Stalled of stop_cause

  let process_active_task ~task ~assignee ~verification_id =
    match Atomic.get active_runtime with
    | None -> false
    | Some runtime -> process_task runtime task ~assignee ~verification_id; true

  let retry_pending ~task_id ~verification_id =
    match Atomic.get active_runtime with
    | None -> false
    | Some runtime ->
      match Atomic.get runtime.retry_pending with
      | None -> false
      | Some batch -> batch.sweep || Review_keys.mem {task_id;verification_id} batch.keys

  let not_reviewed_of_result = not_reviewed_of_result
  let retry_request_of_stop_cause = retry_request_of_stop_cause
  let retry_delay_sec = retry_delay_sec
  let stall_disposition_of_scheduling = stall_disposition_of_scheduling
  let stop_cause_label = stop_cause_label
  let stalled_gate = stalled_gate
  let stall_log_line = stall_log_line
  let announce_stall = announce_stall

  type nonrec review_key = review_key =
    { task_id : string
    ; verification_id : string
    }

  type nonrec scan_scope = scan_scope =
    | Whole_backlog
    | Targets of review_key list

  let entries_in_scope = entries_in_scope

  let make_retry_scheduler ~sw ~wait ~dispatch =
    let pending = Atomic.make None in
    queue_retry ~sw ~wait ~dispatch pending
  ;;

  type nonrec admission = admission =
    | Review_completion
    | Not_awaiting

  let admission_of_status = admission_of_status
end
