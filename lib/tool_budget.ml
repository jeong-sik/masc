(** Tool description budget limiter.

    Ranks tools by tier and usage frequency, truncates when budget exceeded.
    Token estimation: ~4 characters per token (conservative approximation). *)

(** CJK-aware token estimate delegated to OAS Context_reducer. *)
let estimate_tokens (s : string) : int =
  if s = "" then 0 else Agent_sdk.Context_reducer.estimate_char_tokens s

let tier_rank (name : string) : int =
  match Tool_catalog.tool_tier name with
  | Tool_catalog.Core -> 0
  | Tool_catalog.Extended -> 1

let filter_by_budget ~budget_tokens ~usage_counts
    ~(tool_schemas : Types.tool_schema list) : Types.tool_schema list =
  if budget_tokens <= 0 then []
  else
    (* Sort: tier ascending (Core first), then usage descending *)
    let sorted =
      List.sort
        (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
          let ta = tier_rank a.name in
          let tb = tier_rank b.name in
          if ta <> tb then Int.compare ta tb
          else
            (* Higher usage first *)
            Int.compare (usage_counts b.name) (usage_counts a.name))
        tool_schemas
    in
    (* Accumulate tools until budget is exhausted *)
    let _remaining, accepted =
      List.fold_left
        (fun (remaining, acc) (schema : Types.tool_schema) ->
          if remaining <= 0 then (remaining, acc)
          else
            let cost = estimate_tokens schema.description in
            (* Always include if we have any budget left, even if it slightly
               exceeds the limit. This avoids dropping a tool that barely
               overflows. *)
            (remaining - cost, schema :: acc))
        (budget_tokens, []) sorted
    in
    List.rev accepted

let default_budget () : int option =
  Env_config.Tools.description_budget_opt ()
