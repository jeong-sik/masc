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

type t

(** Resolve and snapshot one runtime assignment.  A lane is deliberately
    [Unavailable]: choosing one of its candidates here would guess which
    provider actually handled the turn. *)
val capture : request -> t

val captured_evidence : t -> evidence

type committed

(** Bind the captured target to the exact SHA-bearing checkpoint reference
    returned by the successful source CAS. This is pure and performs no
    observation or I/O. *)
val bind_committed_checkpoint : Keeper_checkpoint_ref.t -> t -> committed

val committed_evidence : committed -> evidence
val checkpoint_ref : committed -> Keeper_checkpoint_ref.t
