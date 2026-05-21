(** Provider capability snapshot used at the cascade boundary before
    dispatching to OAS.

    Phase A wires the boundary with [unknown] snapshots only, so routing
    behavior is unchanged. Later phases can replace the snapshot producer with
    provider/OAS evidence and the same decision function becomes active. *)

type t =
  { provider_name : string
  ; satisfying_tools_snapshot : string list option
  ; tool_choice_support : bool option
  }

type unsupported =
  { missing_tools : string list
  ; tool_choice_required : bool
  ; tool_choice_supported : bool option
  }

type decision =
  | Can_satisfy
  | Cannot_satisfy of unsupported
  | Capability_unknown

val unknown : provider_name:string -> t

val known :
  provider_name:string ->
  satisfying_tools:string list ->
  tool_choice_support:bool ->
  t

val missing_required_tools : t -> required_tools:string list -> string list option

val decide_required_action :
  ?require_tool_choice:bool -> t -> required_tools:string list -> decision

val can_satisfy_required_action :
  ?require_tool_choice:bool -> t -> required_tools:string list -> bool option

val filter_candidates_for_required_tools :
  ?require_tool_choice:bool ->
  t list ->
  required_tools:string list ->
  t list * (t * string list) list

val record_pre_dispatch_required_tool_filtered :
  provider:string -> missing_count:int -> unit
