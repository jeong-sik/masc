(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories. *)

(** {1 Types} *)

(** One non-empty completion-contract statement. There is one semantic value,
    so the wire is the string itself rather than a tagged one-arm union. *)
type criterion = string

val equal_criterion : criterion -> criterion -> bool
val criterion_to_yojson : criterion -> Yojson.Safe.t
val criterion_of_yojson : Yojson.Safe.t -> (criterion, string) result

(** A stored file the current schema cannot read, carried as a value so one
    such file does not decide the fate of the requests beside it. Nothing here
    accepts a superseded schema — an unreadable file stays unreadable. *)
type unreadable_request = {
  unreadable_path: string;
  unreadable_detail: string;
}

val unreadable_to_yojson : unreadable_request -> Yojson.Safe.t

type verification_request = {
  id: string;
  task_id: string;
  output: Yojson.Safe.t;
  criteria: criterion list;
  worker: string;
  created_at: float;
}

(** What one pass over the request directory found. Callers report both fields:
    [readable] alone is a silent drop, and failing the scan over one entry in
    [unreadable] loses every readable request with it. *)
type request_scan = {
  readable: verification_request list;
  unreadable: unreadable_request list;
}

(** {1 Serialization} *)

val request_to_yojson : verification_request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (verification_request, string) result

(** {1 Storage} *)

val generate_id : unit -> string

(** [delete_request base_path req_id] removes the verification record for
    [req_id]. RFC-0221 §3.1 compensation: undo a record write whose Task status
    commit did not land. A missing record is success (idempotent). *)
val delete_request : string -> string -> (unit, string) result

val load_request : string -> string -> (verification_request, string) result
val list_requests : string -> (request_scan, string) result
(** Missing storage is an empty scan. A file the schema cannot read lands in
    [unreadable] with its path and the parse detail, and every file that did
    read lands in [readable] — one bad file no longer costs the rest. [Error]
    is reserved for the directory itself being unenumerable, where neither
    list is known.

    Each unreadable entry still increments the [persistence_read_drops] counter
    at read time, so the metric keeps meaning "this many records did not make
    it into the projection". *)

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
