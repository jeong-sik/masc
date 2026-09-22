(** Advisory applicability of an already authorized, frozen Instruction Skill.
    A verdict never changes Skill selection, authorization or activation. *)
type decision = Applicable | Not_applicable | Insufficient_context

type t

val assess :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_id:string ->
  context:Yojson.Safe.t option ->
  reference:Skill_reference.t ->
  body:string ->
  unit -> t
(** Explicit TOML opt-in and keeper exclusions precede any HTTP request.
    Transport and response failures become advice-unavailable observations;
    cancellation propagates to the caller. *)

val to_yojson : t -> Yojson.Safe.t
val model_advice : t -> string option
(** [None] when policy disables review or required input/question material is
    unavailable before a request. Returned judgments and HTTP/response failures
    produce short advice without turning the assessment into a gate. *)
