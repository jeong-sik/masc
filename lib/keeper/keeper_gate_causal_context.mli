(** Explicit turn-local causal evidence for contextual Gate judgment.

    The cell is created once by the outer Keeper turn and threaded through the
    OAS tool bundle. Each completed Tool appends its exact typed input/result.
    [snapshot] returns immutable JSON for one later Gate request. No global,
    string-keyed, or fiber-local carrier is used. *)

type t

val create : turn_id:int option -> initial:Yojson.Safe.t -> t

val record_tool_result :
  t -> operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit

val snapshot : t -> Keeper_gate.causal_context
