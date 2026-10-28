(** Durable publication authority. No chat or Board messages are emitted. *)
type error =
  | Invalid of string
  | Missing
  | Conflict of { expected : int; actual : int }
  | Unavailable of string
  | Commit_uncertain of { id : string; revision : int; message : string }
type listing =
  { artifacts : Yojson.Safe.t list
  ; diagnostics : (string * string) list
  }
val error_message : error -> string
val publish : base_path:string -> author:string -> Published_artifact.request ->
  (Published_artifact.t * Published_artifact.revision, error) result
(** On a revision, an omitted Task or Goal reference retains the preceding
    revision's reference, JSON null clears it and a string sets it. Creation
    treats omitted and null references as absent. *)
val list : base_path:string -> (listing, error) result
val list_with_authors : base_path:string -> (listing, error) result
(** The same latest-publication inventory and diagnostics as [list], with an
    [authors] array containing all distinct authors recorded in each artifact's
    revision history. This is a metadata read; it does not read revision bodies
    or establish current editor presence. *)
val read : base_path:string -> id:string -> revision:int option ->
  (Published_artifact.t * Published_artifact.revision * string, error) result
val with_latest_locked : base_path:string -> id:string -> expected_revision:int ->
  f:(Published_artifact.revision -> string -> 'a) -> ('a, error) result
(** Acquire the same per-artifact lock as [publish], then read and validate the
    current revision and its exact source before calling [f]. The callback is
    not called if the current revision differs from [expected_revision]. Its
    value is preserved if lock release reports an error; exceptions, including
    cancellation, are propagated after release. The callback runs in a system
    thread and must use blocking operations only, without Eio effects; it must
    not publish or acquire this artifact's publication lock recursively. This only locks
    the publication: callers coordinating another store must also use that
    store's own concurrency boundary. *)
val is_shared : base_path:string -> id:string -> (bool, error) result
val set_shared : base_path:string -> id:string -> shared:bool -> (bool, error) result
