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
val list : base_path:string -> (listing, error) result
val read : base_path:string -> id:string -> revision:int option ->
  (Published_artifact.t * Published_artifact.revision * string, error) result
val is_shared : base_path:string -> id:string -> (bool, error) result
val set_shared : base_path:string -> id:string -> shared:bool -> (bool, error) result
