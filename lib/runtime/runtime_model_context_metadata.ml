let find ~provider_id ~model entries =
  match Agent_core.Provider_runtime_binding.find provider_id,
        Llm_provider.Model_identifiers.Model_id.of_string model with
  | None, _ | Some _, Error _ -> None
  | Some binding, Ok requested ->
    let contexts = entries |> List.filter_map (fun (entry:Llm_provider.Model_catalog.model_entry) ->
      let provider = match entry.provider_name with
        | Some name -> name=binding.id || List.mem name binding.aliases
        | None -> false in
      let same raw = match Llm_provider.Model_identifiers.Model_id.of_string raw with
        | Ok id -> Llm_provider.Model_identifiers.Model_id.equal id requested
        | Error _ -> false in
      let exact = Llm_provider.Model_identifiers.Model_id.equal entry.model_id requested
        || Option.fold ~none:false ~some:(List.exists same) entry.supported_models in
      match entry.max_context_tokens with
      | Some context when provider && exact && context>0 -> Some context
      | _ -> None) |> List.sort_uniq Int.compare in
    match contexts with [context] -> Some context | _ -> None
