(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories. *)

(** {1 Types} *)

(** One constructor, because one is what is produced: request criteria are
    built as [Custom] over the task's completion contract, and the completion
    authority accepts only [Custom]. The wire tag stays ["custom"]. *)
type criterion = Custom of string

val show_criterion : criterion -> string
val equal_criterion : criterion -> criterion -> bool
val criterion_to_yojson : criterion -> Yojson.Safe.t
val criterion_of_yojson : Yojson.Safe.t -> (criterion, string) result

type verification_request = {
  id: string;
  task_id: string;
  output: Yojson.Safe.t;
  criteria: criterion list;
  worker: string;
  created_at: float;
}

(** {1 Serialization} *)

val request_to_yojson : verification_request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (verification_request, string) result

(** {1 Storage} *)

val generate_id : unit -> string
val save_request : string -> verification_request -> (string, string) result

(** [delete_request base_path req_id] removes the verification record for
    [req_id]. RFC-0221 §3.1 compensation: undo a record write whose Task status
    commit did not land. A missing record is success (idempotent). *)
val delete_request : string -> string -> (unit, string) result

val load_request : string -> string -> (verification_request, string) result
val list_requests : string -> verification_request list

(** {1 High-level API} *)

val create_request :
  base_path:string ->
  task_id:string ->
  output:Yojson.Safe.t ->
  criteria:criterion list ->
  worker:string ->
  ?request_id:string ->
  unit ->
  (verification_request, string) result
