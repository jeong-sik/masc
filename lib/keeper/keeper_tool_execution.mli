(** Producer-owned Keeper execution result.

    [deferred_kind] distinguishes a generic deferred tool transition from a
    deferred external effect. It is producer-owned and must never be recovered
    by parsing the opaque provider-facing tool body. *)
type deferred_kind =
  | Generic_deferred
  | External_effect_deferred

val deferred_kind_to_string : deferred_kind -> string
(** Stable producer-owned wire label for deferred settlement evidence. *)

type terminal_effect_receipt =
  | Surface_post_completed of Keeper_surface_post.post_target
(** Producer-owned proof of the concrete terminal effect that completed. *)

(** [disposition] uses the canonical {!Tool_result.disposition}; this module
    deliberately defines no parallel outcome enum.  [raw_output] is opaque
    text. [data] and [metadata] exist only when the producer supplied them. *)

type t = private
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; metadata : Yojson.Safe.t option
  ; failure_effect_disposition : Tool_result.failure_effect_disposition
      (** Meaningful only for [Failed]. Generic producers default to
          [Effect_outcome_unknown]; terminal-effect producers must state the
          strongest phase they can prove. *)
  ; disposition :
      (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition
  ; deferred_kind : deferred_kind option
  ; terminal_effect_receipt : terminal_effect_receipt option
  }

val success : string -> t

(** Typed completion. [raw_output] is the deterministic JSON rendering used by
    text-only consumers; typed consumers use [data] directly. *)
val success_data : ?metadata:Yojson.Safe.t -> Yojson.Safe.t -> t

(** Typed deferral. [metadata] is an opaque one-way AGENT_CORE projection, never a
    source from which MASC recovers the disposition. *)
val deferred_data : ?metadata:Yojson.Safe.t -> Yojson.Safe.t -> t

(** Typed deferral for an external effect whose durable resolution resumes the
    Keeper later. *)
val deferred_external_effect_data : ?metadata:Yojson.Safe.t -> Yojson.Safe.t -> t

val failure
  :  ?class_:Tool_result.tool_failure_class
  -> ?effect_disposition:Tool_result.failure_effect_disposition
  -> string
  -> t

(** Typed failure with a separate opaque human-readable [message]. *)
val failure_data
  :  class_:Tool_result.tool_failure_class
  -> ?effect_disposition:Tool_result.failure_effect_disposition
  -> message:string
  -> Yojson.Safe.t
  -> t

(** Preserve the already committed Gate authorization and its audit receipts
    on every disposition, including a later tool failure. *)
val with_gate_authorization : Keeper_gate.authorization -> t -> t

val with_surface_post_receipt : Keeper_surface_post.post_target -> t -> t
(** Attach the resolved post target only to a completed execution. *)

(** Preserve the authoritative {!Tool_result.disposition} from a normal MASC
    handler. A [`String] payload stays opaque and is never interpreted as
    JSON. *)
val of_tool_result : Tool_result.result -> t
