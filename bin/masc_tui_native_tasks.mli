(** Independent native-task observations. Neither root-turn settlement nor an
    absent receiver/task is evidence of task completion or process liveness. *)
module Read = Masc.Keeper_native_task_read
module Task = Runtime_native_tasks

type error =
  | Transport of string
  | Http_refused of int
  | Invalid_json of string
  | Invalid_response of Read.decode_error
  | Service of Read.failure
  | Persistence of Read.receiver * Read.error_code
  | Receiver_read of Read.receiver * error

type task = private
  { store_id : string
  ; origin : Task.origin
  ; status : Task.status option
  ; terminal : Task.terminal option
  ; subagent_type : string option
  ; usage : Task.usage option
  ; last_tool_name : string option
  ; skip_transcript : bool option
  ; ambient : bool option
  ; is_backgrounded : bool option
  ; end_time : int option
  ; total_paused_ms : int option
  ; reason : Task.reason option
  ; boundary : Task.boundary
  }

type read_mode = Audit | Poll
type t
val empty : t
val failed : t -> error -> t
val tasks : t -> task list
(** Retains task identity in full, including original execution, invocation,
    native call and run. Does not merge by task ID or current root turn. *)
val errors : t -> error list
val diagnostics : t -> string list
(** Coverage and cleanup warnings, never interpreted as task state. *)
val error_text : error -> string

val read : mode:read_mode -> keeper_name:string ->
  fetch:(string -> (int * string, string) result) -> previous:t ->
  (t, error) result
(** Sequential discovery and per-incarnation suffix reads. Successful pages
    must match their exact request. A failed receiver retains its previous
    observations and cursor; another receiver can still advance. A newly
    discovered store incarnation starts a distinct history from sequence 1.
    Disappearance never deletes retained history. The caller supplies and
    checks workspace authority before each HTTP read and at mailbox delivery. *)

(** [Poll] reads unchecked metadata hints and fully audits changed stores only.
    Same-tail historical tampering is not detected by hints. A failed audited read
    is retained without repeating full scans until the hint changes or [Audit].
    [Audit] always runs fully audited discovery and retries failed record reads. *)
