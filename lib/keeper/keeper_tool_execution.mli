(** Producer-owned Keeper execution result.

    [disposition] uses the canonical {!Tool_result.disposition}; this module
    deliberately defines no parallel outcome enum.  [raw_output] is opaque
    text. [data] and [metadata] exist only when the producer supplied them. *)

type t = private
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; metadata : Yojson.Safe.t option
  ; disposition :
      (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition
  }

val success : string -> t

(** Typed completion. [raw_output] is the deterministic JSON rendering used by
    text-only consumers; typed consumers use [data] directly. *)
val success_data : ?metadata:Yojson.Safe.t -> Yojson.Safe.t -> t

(** Typed deferral. [metadata] is an opaque one-way OAS projection, never a
    source from which MASC recovers the disposition. *)
val deferred_data : ?metadata:Yojson.Safe.t -> Yojson.Safe.t -> t

val failure
  :  ?class_:Tool_result.tool_failure_class
  -> string
  -> t

(** Typed failure with a separate opaque human-readable [message]. *)
val failure_data
  :  class_:Tool_result.tool_failure_class
  -> message:string
  -> Yojson.Safe.t
  -> t

(** Preserve the authoritative {!Tool_result.disposition} from a normal MASC
    handler. A [`String] payload stays opaque and is never interpreted as
    JSON. *)
val of_tool_result : Tool_result.result -> t
