(** Pause-status projection for workspace/tool surfaces. *)

type keeper_pause_status =
  | Workspace_not_initialized
      (** No Keeper census exists yet, so whether any Keeper is paused is
          unknown. *)
  | Census of
      { paused_names : string list
      ; read_errors : (string * string) list
      }
      (** Keepers paused by meta or by registry phase, without duplicates,
          and the Keepers whose meta could not be read. *)

val keeper_pause_status : Workspace.config -> (keeper_pause_status, string) result
(** [Error] when the Keeper directory could not be read. An unread census
    cannot establish that no Keeper is paused. *)

val keeper_pause_status_to_json : keeper_pause_status -> Yojson.Safe.t
(** The one place both cases are written, so they emit the same keys:
    [paused], [paused_count], [paused_names], [read_errors]. An uninitialised
    workspace has [null] for the first two. *)
