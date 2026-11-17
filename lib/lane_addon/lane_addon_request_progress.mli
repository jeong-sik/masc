(** Host-owned facts about one retained request. Recording a fact does not
    dispatch a worker, validate a model answer, authorize an effect or save a
    domain state. The original host adapter owns all of those boundaries. *)
type observation = Waiting of Yojson.Safe.t | Outcome_unknown of Yojson.Safe.t
  | Absent of Yojson.Safe.t
type refusal_stage = Before_dispatch | Execution
type refusal = { stage : refusal_stage; evidence : Yojson.Safe.t }
type change = { before : Yojson.Safe.t; after : Yojson.Safe.t }
type commit = { judgment : Yojson.Safe.t; change : change }
type successor = { request_id : string; request_digest : string }
(** The child request by its original request ID and the digest its owner
    record names it by; the child's body is stored once, by its own record. *)
type preparation_intent = { request_id : string; request : Yojson.Safe.t }
type preparation = Preparation_pending of preparation_intent | Preparation_confirmed of preparation_intent
type approval =
  | Intent_pending of Lane_addon_request_approval.intent
  | Waiting_for_approval of Lane_addon_request_approval.intent * Lane_addon_request_approval.wait
type event =
  | Approval_intended of Lane_addon_request_approval.intent
  | Approval_wait_retained of Lane_addon_request_approval.wait
  | Dispatch_intended
  | Admission_declined of Yojson.Safe.t
  | Execution_observed of observation
  | Judgment_retained of Yojson.Safe.t
  | Preparation_intended of preparation_intent
  | Preparation_observed of string
  | Replacement_intended of preparation_intent
  | Replacement_observed of string
  | Commit_intended of change
  | Commit_uncertain of Yojson.Safe.t
  | Commit_retry_observed of Yojson.Safe.t
  | Commit_observed of Yojson.Safe.t
  | Commit_conflicted of Yojson.Safe.t
  | Refused of refusal
  | Refusal_settled of Yojson.Safe.t
  | Successor_intended of successor
  | Successor_observed of string
  | Observer of Lane_addon_request_receipt.event
type phase = Captured | Admission_wait of Yojson.Safe.t | Dispatch_pending of observation option
  | Judged of Yojson.Safe.t | Committing of commit
  | Commit_unknown of commit * Yojson.Safe.t | Finished of commit
  | Conflicted of commit * Yojson.Safe.t | Rejected of refusal
  | Subdividing of refusal * successor | Subdivided of refusal * successor
type t
val captured : t
val phase : t -> phase
val events : t -> event list
val approval : t -> approval option
(** Optional immutable approval facts, independent of the execution phase.
    [None] means no approval intent was recorded, not that an approval is
    absent from its queue. One intent and its exact wait link may be appended
    only while [Captured]; neither changes that phase. The wait must match
    the intent digest and complete request input hash. Duplicate or rebound
    intents/links are rejected, and every later phase preserves these facts.
    No intent is required for generic dispatch: each domain owner validates
    its own original binding and authorization. A retained wait is not Allow,
    an execution observation, or the [Admission_wait] refusal phase. *)
val preparation : t -> preparation option
(** Optional immutable prerequisite-publication fact. Its intent and exact ID
    acknowledgement preserve Judged; they perform no child publication or
    execution and grant no domain effect. The host separately authenticates
    the complete original child, parent and physical owner. Pending preparation
    prevents Commit_intended; consumers without one keep their original policy. *)
val replacement : t -> preparation option
(** Orthogonal immutable replacement-publication fact, allowed while the
    original remains Conflicted or Rejected. One complete successor intent and its exact ID
    acknowledgement survive restart without altering the original phase, Gate
    preparation or observer. The host must authenticate the full derivation and
    confirm the retained child before ACK; neither event grants RPC permission.
    A refusal needs consumer-owned proof that replacement is permitted. A
    replacement intent prevents later subdivision or refusal settlement. *)
val settlement : t -> Yojson.Safe.t option
(** Orthogonal immutable fact, allowed only on an execution refusal: the host
    completed its consumer-owned disposition and retained the evidence. This
    may abandon a refused range or release a stopped original for a new
    request while keeping its source unread. Phase stays
    [Rejected]; the refusal evidence is not rewritten. Once present, the
    original can no longer be subdivided, and a second settlement is an error.
    The event grants no effect. Each consumer validates the exact disposition;
    if it moves ranges, it must apply them before recording the fact. A release
    without consumption grants no range, Memory or cursor acknowledgement. *)
val observer : t -> Lane_addon_request_receipt.t
(** Orthogonal immutable observer intents/acknowledgements. Execution and commit
    transitions preserve them. Completion intent requires an original Finished,
    Conflicted or Refused (including its successor-link phases) fact. The domain
    owner must additionally validate the entire receipt against its original
    capture/judgment and confirm registry durability before recording an ACK. *)
val append : t -> event -> (t, string) result
(** Canonicalize payloads and validate the next transition. Dispatch is recorded
    before each admission RPC. Only an admission declined because it was not
    sent allows a later admission of the same captured request. Waiting,
    unknown and worker absence never permit redispatch. A declined admission is
    accepted only immediately after dispatch intent, before any execution
    observation.
    A late original judgment preserves earlier observations in the history.
    Commit retry requires a fresh exact before-state observation; confirmation
    requires the exact captured after-state. An execution or before-dispatch
    refusal can retain one immutable successor intent and acknowledge that same
    child's ID; a settled execution refusal cannot. The refusal itself
    remains terminal; neither fact permits redispatch or
    establishes that this consumer may narrow. The host checks that policy,
    whole-child derivation and durable parent acknowledgement before admission.
    Neither observation performs I/O. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strictly decode and fold the complete ordered history from Captured.
    Decode each event once, then fold its validated value without encoding and
    decoding it again. Unknown fields/events, invalid JSON, receipt digest
    mismatches and invalid transitions are errors. *)
