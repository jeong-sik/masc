(** Typed admission boundary for dashboard-initiated Keeper purge operations.

    Resolution never guesses a Keeper from filesystem side effects. The
    request is normalized once through {!Keeper_identity}; a Keeper target is
    admitted only when its canonical persisted metadata can be read. A
    configuration-only or unreadable Keeper remains explicit and cannot fall
    through to the plain-agent purge path. *)

type target =
  { requested_name : string
  ; keeper_name : string
  ; meta : Keeper_meta_contract.keeper_meta
  }

type resolve_error =
  | Empty_requested_name
  | Invalid_requested_name of
      { requested_name : string
      ; detail : string
      }
  | Keeper_metadata_unreadable of
      { keeper_name : string
      ; metadata_path : string
      ; detail : string
      }
  | Keeper_metadata_required of
      { keeper_name : string
      ; configuration_path : string
      }
  | Keeper_metadata_name_mismatch of
      { expected_keeper_name : string
      ; persisted_keeper_name : string
      }
  | Keeper_agent_name_invalid of
      { keeper_name : string
      ; agent_name : string
      ; detail : string
      }
  | Keeper_operation_unreadable of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }

val resolve_error_to_string : resolve_error -> string

(** [resolve config requested_name] returns [Ok (Some target)] only for a
    canonical Keeper backed by readable persisted metadata. [Ok None] means
    the request has no Keeper metadata/configuration ownership and may be
    considered by the separate plain-agent boundary. *)
val resolve :
  Workspace.config -> string -> (target option, resolve_error) result

(** Return the exact dashboard purge operation that currently owns the
    canonical Keeper's admission fence. This makes an HTTP retry idempotent
    even after finalization removed metadata but completion delivery is still
    pending. An unrelated lifecycle operation is not reclassified as purge. *)
val existing_operation :
  Workspace.config ->
  string ->
  (Keeper_shutdown_types.t option, resolve_error) result

(** Persist and asynchronously start an exact-owner dashboard purge. The
    returned operation id is durable before [submit] returns. *)
val submit :
  config:Workspace.config ->
  actor:string ->
  target ->
  (Keeper_shutdown_types.t, Keeper_shutdown_runtime.submit_error) result
