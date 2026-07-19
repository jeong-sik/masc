(** Immutable provider/model target for measuring a committed compaction.

    The opaque value captures the materialized provider configuration exactly
    once, before compaction planning starts.  Public evidence is a distinct
    credential-free type, so an API key, endpoint, or header cannot be
    serialized through this module. *)

type context_window_resolution =
  | Resolved_context_window of int
  | Context_window_not_resolved
  | Invalid_context_window of int

type request

(** Build a prepare-time capture request. [assignment_id] is preserved byte for
    byte. [resolve_context_window] receives the same immutable [Runtime.t]
    snapshot that will supply the provider configuration. *)
val request :
  assignment_id:string ->
  resolve_context_window:(Runtime.t -> context_window_resolution) ->
  request

(** Capture the exact immutable runtime already selected for a provider turn.
    This path performs no registry lookup, so a later runtime reload cannot
    change the provider/model attributed to an overflow recovery. *)
val exact_request :
  runtime:Runtime.t -> effective_max_context:int -> request

type unavailable =
  | Empty_assignment
  | Assignment_ambiguous of { assignment_id : string }
  | Runtime_unavailable of { runtime_id : string }
  | Context_window_unavailable of { runtime_id : string }
  | Invalid_effective_context_window of
      { runtime_id : string
      ; effective_max_context : int
      }

type exact =
  { runtime_id : string
  ; provider_id : string
  ; protocol : string
  ; oas_provider_kind : string
  ; model_id : string
  ; effective_max_context : int
  }

type evidence =
  | Exact of exact
  | Unavailable of unavailable

val evidence_to_json : evidence -> Yojson.Safe.t
val evidence_of_json : Yojson.Safe.t -> (evidence, string) result

type t

(** Resolve and snapshot one runtime assignment.  A lane is deliberately
    [Unavailable]: choosing one of its candidates here would guess which
    provider actually handled the turn. *)
val capture : request -> t

val captured_evidence : t -> evidence

type committed

(** Bind the captured target to the exact SHA-bearing checkpoint reference
    returned by the successful source CAS, and prepare the canonical OAS
    request projection for that exact saved checkpoint. This is pure and
    performs no observation or I/O. *)
val bind_committed_checkpoint :
  checkpoint:Agent_sdk.Checkpoint.t -> Keeper_checkpoint_ref.t -> t -> committed

val committed_evidence : committed -> evidence
val checkpoint_ref : committed -> Keeper_checkpoint_ref.t

type target_unavailable = unavailable

module Fit : sig
  type context =
    { input_tokens : int
    ; reserved_output_tokens : int
    ; max_context_tokens : int
    }

  type unavailable =
    | Projection_target_unavailable of target_unavailable
    | Input_count_failed of Llm_provider.Input_token_count.error
    | Output_token_ceiling_missing
    | Invalid_completion_request of string
    | Context_limit_unknown of { model_id : string }
    | Invalid_context_limit of
        { model_id : string
        ; max_context_tokens : int
        }
    | Output_reservation_unknown of { model_id : string }

  type t =
    | Fits of context
    | Exceeds of context
    | Unavailable of unavailable
end

type fit_evidence = private
  { checkpoint_ref : Keeper_checkpoint_ref.t
  ; target : evidence
  ; result : Fit.t
  }

val fit_evidence_to_json : fit_evidence -> Yojson.Safe.t

(** Native-count then admit the same opaque request; no estimate, truncation,
    retry, lookup, or completion occurs. Cancellation propagates. [Fit.Fits]
    proves only the committed checkpoint: future dispatch retains OAS
    admission. Callers schedule and persist this I/O outside Keeper admission. *)
val measure_checkpoint_fit :
  ?connection_cache:Llm_provider.Http_client.cache ->
  ?clock:_ Eio.Time.clock ->
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  committed ->
  fit_evidence
