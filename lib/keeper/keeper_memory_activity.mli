(** Read-only, bounded memory change history projected from a Keeper's Memory
    commit log ([<keeper>.memory-log.jsonl]). These observations grant no
    restoration, deletion or publication authority. *)

type kind =
  | Created
  | Reobserved
  | Revised
  | Absorbed
  | Retracted
  | Removed
  | Invalidated
  | Relation_unavailable

type fact =
  { memory_id : string
  ; claim : string option
  }
(** [None] is an unresolved successor identity, never a confirmed claim. *)

type event =
  { identity : string
  ; recorded_at : float
  ; revision : int
  ; kind : kind
  ; before : fact list
  ; after : fact list
  ; reason : string option
  }

type t =
  { limit : int
  ; journal_lines : int
  ; events : event list
  ; notes : string list
  }

val project_commit
  :  ?lookup_fact:(string -> Keeper_memory_os_types.fact option)
  -> identity:string
  -> Librarian_log.commit
  -> (event list, string) result
(** Project one committed {!Librarian_log.commit} row into typed activity
    events. [lookup_fact] resolves retained successor or re-observed claims
    that were added in an earlier commit. *)

val read : keepers_dir:string -> keeper_id:string -> limit:int -> t
(** Read the last [limit] commit-log lines off the scheduler domain, oldest
    first. Byte offsets supply stable event identities. Read and decode errors
    stay in [notes], distinct from an empty history. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Shared HTTP codec. Unknown kinds, malformed references and invalid clocks
    reject rather than becoming successful empty activity. *)
