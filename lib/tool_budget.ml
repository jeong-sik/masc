(** Tool description budget limiter.

    Ranks tools by usage frequency, truncates when budget exceeded.
    Token estimation: ~4 characters per token (conservative approximation). *)

(** CJK-aware token estimate delegated to OAS Context_reducer. *)
let estimate_tokens (s : string) : int =
  if s = "" then 0 else Agent_sdk.Context_reducer.estimate_char_tokens s

let filter_by_budget ~budget_tokens ~usage_counts
    ~(tool_schemas : Types.tool_schema list) : Types.tool_schema list =
  if budget_tokens <= 0 then []
  else
    (* Sort: higher usage first, then name for deterministic output. *)
    let sorted =
      List.sort
        (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
          let usage_cmp =
            Int.compare (usage_counts b.name) (usage_counts a.name)
          in
          if usage_cmp <> 0 then usage_cmp
          else
            String.compare a.name b.name)
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
