(** Rejection delivery obligations committed with the Task verdict. *)
val pending :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.pending_completion_rejection list, string) result

(** Moves the exact pending rejection to a delivered receipt. A stale
    acknowledgement cannot install an old receipt or retire a newer rejection.
    Pending and delivered receipts both retain current consumer authority. *)
val acknowledge :
  Workspace_utils_backend_setup.config ->
  task_id:string -> verification_id:string -> (unit, string) result

type standing = Current | Obsolete

val standing_in_backlog :
  Masc_domain.backlog ->
  task_id:string -> verification_id:string -> producer:string -> reason:string ->
  authority:Masc_domain.completion_authority -> (standing, string) result
(** Classify an exact payload against the current typed relation and Task
    owner in one authoritative snapshot. A replaced relation is obsolete.
    With no relation, InProgress under the same producer cannot establish which
    rejection is current and returns an error so intake preserves its source.
    A missing Task or another owner/state positively makes that source obsolete.
    Conflicting payloads or relation/Task inconsistencies are errors. *)

val standing :
  Workspace_utils_backend_setup.config ->
  task_id:string -> verification_id:string -> producer:string -> reason:string ->
  authority:Masc_domain.completion_authority -> (standing, string) result
(** An authoritative read at intake, not a grant for later Task mutations.
    Unreadable or recovered storage is an error, never an obsolete result. *)

type 'a publication = Published of 'a | Superseded

val deliver_if_pending :
  Workspace_utils_backend_setup.config ->
  task_id:string -> verification_id:string -> producer:string -> reason:string ->
  authority:Masc_domain.completion_authority ->
  deliver:(unit -> ('a, string) result) -> ('a publication, string) result
(** Under the backlog lock and its lease fence, reread authority and publish
    only a still-pending exact rejection. The caller must acquire the Keeper
    intake token before this call and must not reacquire it in [deliver].
    [deliver] performs only durable queue publication; notifications, wakeup
    and source acknowledgement run after this function releases its locks.
    A delivered receipt or absent exact pending identity never authorizes a new
    queue publication: it returns [Superseded] before consumer standing checks.
    This cannot be used as evidence to discard an existing queued source. *)
