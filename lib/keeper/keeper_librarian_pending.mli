(** Why an observed Librarian pass remains unfinished. This is an
    observation of that pass, never permission to replay a request or ACK input. *)
type worker_wait =
  | Capacity
  | Processing
  | Outcome_unknown
  | Unreachable
  | Missing_after_dispatch
  | Journal_recheck

type worker = { installation_id : string; request_id : string; wait : worker_wait }

type t =
  | Worker of worker
  | Publication of { request_id : string; detail : string }
  | Basis_changed of { request_id : string }
  | Message_floor of { request_id : string; detail : string }
  | Local_failure of string
      (** A callback failed before it could return a publication result. The
          durable consumer's caller promotes this to its original error. *)

type admission =
  | Admission_waiting of worker
  | Admission_failed of string
      (** The explicit-admission pass ended with its own error before it could
          judge, commit or wait. The text is that error. *)
(** What the latest explicit-admission pass of one Keeper left unfinished. *)

val admission_pending : admission -> t
(** The same observation as a pending value: a failed pass is a
    [Local_failure]. This is its wire form. *)

val admission_of_pending : t -> (admission, string) result
(** Refuses the durable-only observations. *)

val admission_description : admission -> string

val of_worker_wait :
  installation_id:string -> request_id:string -> Lane_addon_submit_once.wait -> worker
(** Preserve the actual original and classify its shared submit-once wait once.
    The observation grants no admission, replay or source-consumption authority. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val description : t -> string
val needs_attention : t -> bool
(** An unconfirmed execution or failed local recovery needs explicit attention;
    a waiting worker is not declared failed by elapsed time or backlog size. *)

val attention_required : durable:t option -> admission:admission option -> bool
(** Derive one Keeper's attention requirement from its independent durable and
    admission observations. A failed admission pass requires attention.
    [None] is no observed wait or failure, not completion. *)
