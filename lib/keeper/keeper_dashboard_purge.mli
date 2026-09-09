(** Typed admission boundary for dashboard-initiated Keeper purge operations.

    Resolution never guesses a Keeper from filesystem side effects. The
    request is normalized once through the canonical name grammar. A runtime
    target requires readable canonical metadata. A
    configuration-only Keeper is a distinct target; unreadable metadata cannot fall
    through to the plain-agent purge path. *)

type runtime_target =
  { requested_name : string
  ; keeper_name : string
  ; meta : Keeper_meta_contract.keeper_meta
  }

type target =
  | Runtime_keeper of runtime_target
  | Configuration_only of { requested_name : string; keeper_name : string }

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
  | Keeper_metadata_name_mismatch of
      { expected_keeper_name : string
      ; persisted_keeper_name : string
      }
  | Keeper_owner_unavailable of
      { keeper_name : string
      ; detail : string
      }
  | Keeper_operation_unreadable of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }
  | Keeper_purge_blocked of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }
      (** A prior purge holds the admission fence in [Blocked]. It is not in
          flight and no retry advances it: the fence stops the Keeper's meta
          being materialized, and {!resolve} needs that meta. Reporting it as
          an accepted operation told the dashboard a purge was running that
          had already stopped for good. The exit is an operator supersession,
          which releases the fence and lets the purge be reissued. *)

val resolve_error_to_string : resolve_error -> string

(** [resolve config requested_name] returns [Ok (Some target)] only for a
    runtime Keeper or an explicit configuration-only target. [Ok None] means
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
  runtime_target ->
  (Keeper_shutdown_types.t, Keeper_shutdown_runtime.submit_error) result
