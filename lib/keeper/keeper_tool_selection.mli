(** Keeper_tool_selection - deterministic keeper tool-surface selection. *)

(** Deterministic BM25 prefilter: pull tools from [search_index] that are NOT
    in [core], dedupe them, and limit to [selection_limit]. Tool relevance
    comes from the descriptor-backed index rather than query substring gates. *)
val deterministic_prefilter_names
  :  search_index:Agent_sdk.Tool_index.t
  -> query_text:string
  -> selection_limit:int
  -> core:string list
  -> string list

(** Merge the four tool selection layers (core / deterministic_prefilter /
    discovered / llm_selected) into a single ordered, deduped list.
    BM25-relevant tools are placed ahead of generic core. *)
val merge_tool_selection_boundary
  :  core:string list
  -> deterministic_prefilter:string list
  -> llm_selected:string list
  -> discovered:string list
  -> string list
