(** Producer-owned result of a Keeper tool execution.

    [raw_output] is opaque text for the model and telemetry.  [data] is present
    only when the producer supplied typed JSON explicitly.  Consumers must
    branch only on [outcome] and must never recover [data] or [outcome] by
    parsing [raw_output]. *)

type outcome =
  | Succeeded
  | Failed of Tool_result.tool_failure_class

type t =
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; outcome : outcome
  }

val success : string -> t

(** Typed success. [raw_output] is the deterministic JSON rendering used by
    text-only consumers; typed consumers use [data] directly. *)
val success_data : Yojson.Safe.t -> t

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

(** Preserve the typed [Ok]/[Error] constructor and every producer-owned [data]
    variant from a normal MASC handler. A [`String] payload stays opaque and is
    never interpreted as JSON, even when its bytes look like a serialized
    object. *)
val of_tool_result : Tool_result.result -> t
