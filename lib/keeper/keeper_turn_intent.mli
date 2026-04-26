(** Classify a keeper turn's intent (mechanical tool dispatch vs cognitive
    reasoning) to drive per-turn enable_thinking decisions.

    Mechanical turns are dominated by predictable-shape tool dispatch
    (task_claim, board_list, fs_read, shell). Empirically, running these
    with [think=false] is 2-3x faster than [think=true] on qwen3.5-based
    Ollama models while producing the same correct tool call.

    Cognitive turns benefit from thinking: plan, critique, retry after
    error, and open-ended user requests.

    Gating lives in [Keeper_config.keeper_adaptive_thinking_mode ()]; when
    that flag is false, classification is not consulted. *)

type t =
  | Mechanical
  | Cognitive

val equal : t -> t -> bool
val to_string : t -> string

(** [classify ~last_tool_calls ~last_user_message ~retry_count] returns
    [Cognitive] when any of the following holds:
    - [retry_count > 0]
    - [last_user_message] contains a cognitive keyword (plan, why, explain,
      critique, design, debug, decide, rethink)
    - [last_tool_calls = []] (keeper was idle/stuck last turn)
    - Any tool in [last_tool_calls] is outside the mechanical set

    Otherwise returns [Mechanical] — the fast path.

    The mechanical set is a v1 hardcoded list covering the high-frequency
    read-only and CRUD tools; see implementation. A future enhancement can
    move this attribute onto [Tool_dispatch] registry entries. *)
val classify
  :  last_tool_calls:string list
  -> last_user_message:string option
  -> retry_count:int
  -> t

(** Set of tool names considered "mechanical" for classification.
    Exposed so tests can assert coverage and keeper operators can audit
    the list. *)
val mechanical_tools : string list
