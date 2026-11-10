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

val attention_required : durable:t option -> admission:worker option -> bool
(** Derive one Keeper's attention requirement from its independent durable and
    admission observations. [None] is no observed wait, not completion. *)
