(** Descriptor-aware eval tool-call selector for harness and benchmark checks.

    Selectors are observational: they match recorded tool-call evidence
    and must not be used as live keeper control-flow gates or live
    tool-availability policy. *)

type t =
  | Tool_name of string
  | Descriptor_id of string
  | Runtime_handler of string
  | Receipt_label of string * string
  | Eval_tag of string

type call =
  { tool_name : string
  ; route_evidence : Yojson.Safe.t option
  }

val label : t -> string
(** Stable human-readable label used in diagnostics. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse selector JSON.

    Supported shapes:

    - ["tool_execute"] as legacy shorthand for [Tool_name].
    - [{"type":"tool_name","value":"tool_execute"}].
    - [{"type":"descriptor_id","value":"masc.agent.card"}].
    - [{"type":"runtime_handler","value":"Tool_masc_agent_dispatch"}].
    - [{"type":"eval_tag","value":"agent_profile_lookup"}].
    - [{"type":"receipt_label","key":"family","value":"agent_profile_lookup"}]. *)

val matches : t -> call -> bool
(** [matches selector call] returns [true] when the selector matches the
    call's tool name or descriptor route evidence. *)

val requires_route_evidence : t -> bool
(** [requires_route_evidence selector] is [false] only for legacy
    [Tool_name] selectors. Descriptor/runtime/receipt/eval-tag selectors
    cannot be evaluated against name-only evidence. *)
