(** A source-bound model transmission view. Canonical history remains the
    authority; this module neither writes a checkpoint nor schedules recovery. *)
type t

type error =
  | Projection_source_rejected of Keeper_recovery_projection.error
  | Source_prefix_missing of
      { expected_messages : int
      ; actual_messages : int
      }
  | Source_prefix_changed of { message_index : int }
  | Incomplete_transmission of Keeper_transcript_unit.provider_transcript_error
  | Client_projection_not_integrated of { runtime_id : string }
  | Source_reader_unavailable
  (** [Client_projection_not_integrated] is unfinished MASC integration, not a
    provider capability claim or a completed Not_supported acceptance cell. *)

val error_to_string : error -> string
val to_core_error : error -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> error option

(** Only an unintegrated candidate can move to the next declared runtime.
    Source/protocol rejection does not retry the same corrupt transmission. *)
val should_try_next : Agent_core.Error.t -> bool

(** Verifies the actual sealed canonical snapshot against the validated source.
    An open Tool tail remains original: a later real result may complete it. *)
val create
  :  source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> validated:Keeper_recovery_projection.validated
  -> (t, error) result

val source_reference : t -> Keeper_checkpoint_ref.t

(** Requires the exact canonical message prefix. Original segments remain the
    same records; Derived segments are explicitly labeled User context carrying
    source SHA/message range and artifact reader instructions. Newly appended
    messages remain untouched, including real Tool results closing an open tail.
    The full source-plus-suffix and resulting view must satisfy the existing
    provider transcript validator. No closer or Assistant/ToolResult is invented. *)
val project
  :  t
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list, error) result

(** CPU-offloaded view followed by the caller's existing projection/metrics.
    The latter sees its own exact input prefix, so append-only provenance checks
    remain meaningful without pretending the derived view is original history. *)
val model_input_projection
  :  t
  -> ?after:Agent_core.Agent.model_input_projection
  -> Agent_core.Agent.model_input_projection

(** Checks the actually offered canonical artifact-reader schema and execution
    descriptor. Does not inject a reader or bypass a Keeper Tool group. *)
val require_reader : Agent_core.Tool.t list -> (unit, error) result
