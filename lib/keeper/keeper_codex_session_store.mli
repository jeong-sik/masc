(** Durable binding between one Keeper trace and one official Codex thread.

    This is not an OAS checkpoint. Codex owns the thread transcript; MASC owns
    only the exact identity needed to resume it on the next Keeper turn. *)

type t =
  { runtime_id : string
  ; thread_id : string
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; updated_at : float
  }

val path : session_dir:string -> string

val tool_surface_sha256 : Agent_sdk.Tool.t list -> string
(** Stable digest of the exact typed dynamic-tool surface. Tool order,
    parameter order, and JSON object field order do not affect the digest;
    names, descriptions, parameter semantics, and input schemas do. *)

val load : session_dir:string -> (t option, string) result
(** Missing state is [Ok None]. Malformed, retired, or ambiguous state is an
    error and never degrades to a new thread. *)

val save : session_dir:string -> t -> (unit, string) result
(** Strict durable atomic replacement followed by an exact read-back check. *)
