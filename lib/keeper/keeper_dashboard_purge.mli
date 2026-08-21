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
          had already stopped for good. The exit is the authenticated exact
          purge reissue, which keeps the same fence through paused recovery
          materialization and finalization. *)
      (** The lane is still taking turns. Purge deletes the Keeper and every
          store it owns, so a Keeper that can still execute is refused here
          rather than raced: stop or pause it first. The dashboard hides the
          control in the same states, but that is a rendering choice — this is
          the rule. *)
  | Keeper_lane_executing of
      { keeper_name : string
      ; phase : string
      ; live_turn_id : int option
            (** [Some turn_id] when the refusal came from a turn in flight
                rather than from the phase. The chat lane admits turns without
                changing phase, so phase alone does not see it.

                The phase arm is checked first, and an autonomous turn sets
                both signals at once, so [None] here means "the phase refused
                it", not "no turn is running".

                [current_turn_observation] is in-memory only and is cleared by
                [mark_turn_finished]. The chat lane swallows
                [Eio.Cancel.Cancelled] around that call
                ([keeper_turn.ml:861-865]), so a cancelled chat turn can leave
                the marker set and keep refusing purges. Recovery is a server
                restart, which re-registers every Keeper with the field unset,
                or the supervisor sweep that unregisters an exited lane. There
                is no per-Keeper reset: [register_restarting] would do it but
                has no production caller. *)
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
