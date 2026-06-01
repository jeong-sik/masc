type tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

val partition_tool_search_hits
  :  core:string list
  -> core_always:string list
  -> allowed:string list
  -> retrieved:(string * float) list
  -> max_results:int
  -> tool_search_hit_partition

