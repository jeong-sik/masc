(** Keeper_tool_selection - deterministic keeper tool-surface selection. *)

(** Allow a deterministic-prefilter tool only when the user's [query_text]
    passes the corresponding code-* gate; everything else passes through
    unchanged. *)
val allow_deterministic_tool : query_text:string -> string -> bool

(** Deterministic BM25 prefilter: pull tools from [search_index] that are NOT
    in [core], pass [allow_deterministic_tool], and cap at [selection_limit]. *)
val deterministic_prefilter_names
  :  search_index:Agent_sdk.Tool_index.t
  -> query_text:string
  -> selection_limit:int
  -> core:string list
  -> string list

(** Merge the four tool selection layers (core / deterministic_prefilter /
    discovered / llm_selected) into a single ordered, deduped list.
    BM25-relevant tools are placed ahead of generic core to survive downstream
    max_tools truncation. *)
val merge_tool_selection_boundary
  :  core:string list
  -> deterministic_prefilter:string list
  -> llm_selected:string list
  -> discovered:string list
  -> string list

(** Proactive contract enforcement: when a keeper has accumulated
    [passive_streak] >= [streak_threshold] consecutive passive turns and there
    is an [actionable_signal], strip [Passive_status] tools from the surface so
    the model is forced toward Execution or Completion tools.

    Completion tools (stay_silent, release, done, etc.) are never stripped
    because they are the keeper's intentional exit valve. *)
val contract_enforcement_filter
  :  passive_streak:int
  -> streak_threshold:int
  -> actionable_signal:bool
  -> string list
  -> string list
