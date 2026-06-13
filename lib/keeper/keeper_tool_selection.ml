(** Keeper_tool_selection - deterministic keeper tool-surface selection. *)

let deterministic_prefilter_names
      ~(search_index : Agent_sdk.Tool_index.t)
      ~(query_text : string)
      ~(selection_limit : int)
      ~(core : string list)
  : string list
  =
  if selection_limit <= 0
  then []
  else (
    Agent_sdk.Tool_index.retrieve search_index query_text
    |> List.filter_map (fun (name, _) ->
      if List.mem name core then None else Some name)
    |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
    |> List.filteri (fun i _ -> i < selection_limit)
  )
;;

let merge_tool_selection_boundary
      ~(core : string list)
      ~(deterministic_prefilter : string list)
      ~(llm_selected : string list)
      ~(discovered : string list)
  : string list
  =
  let sorted_discovered = List.sort String.compare discovered in
  (* Keep deterministic BM25 hits and explicit discoveries ahead of generic
     core tools. This ordering preserves relevance signals without imposing a
     global visible-tool count limit. Core tools that also appear in
     deterministic_prefilter are deduped (first occurrence wins), so they
     naturally keep their BM25 rank. *)
  let deterministic_floor =
    Keeper_types_profile_toml_normalizers.dedupe_keep_order (deterministic_prefilter @ sorted_discovered @ core)
  in
  Keeper_types_profile_toml_normalizers.dedupe_keep_order (deterministic_floor @ llm_selected)
;;
