(** Tool description budget limiter.

    Ranks tools by tier and usage frequency, truncates when budget exceeded.
    Token estimation: ~4 characters per token (conservative approximation). *)

let estimate_tokens (s : string) : int =
  max 1 ((String.length s + 3) / 4)

let tier_rank (name : string) : int =
  match Tool_catalog.tool_tier name with
  | Tool_catalog.Essential -> 0
  | Tool_catalog.Standard -> 1
  | Tool_catalog.Full -> 2

let filter_by_budget ~budget_tokens ~usage_counts
    ~(tool_schemas : Types.tool_schema list) : Types.tool_schema list =
  if budget_tokens <= 0 then []
  else
    (* Sort: tier ascending (Essential first), then usage descending *)
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
  match Sys.getenv_opt "MASC_TOOL_DESCRIPTION_BUDGET" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some v when v > 0 -> Some v
      | _ -> None)
  | None -> None
