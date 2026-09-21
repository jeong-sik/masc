(** Read-only observations of serialized Agent Core requests. These do not
    authorize history removal or prove a provider accepted the request. *)
type frontier = { trace_id : string; end_atom : int; boundary_line : int }
type input = Summarized of frontier | Uncompressed | Not_applied
type t =
  { prepared_at : float
  ; runtime_id : string
  ; input : input
  ; request_bytes : int
  }
val record : config:Workspace.config -> keeper_name:string -> t -> unit
val latest : config:Workspace.config -> keeper_name:string -> t option
val forget : config:Workspace.config -> keeper_name:string -> unit
