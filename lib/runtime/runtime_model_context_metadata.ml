let find ~provider_id ~model entries =
  match Agent_core.Provider_runtime_binding.find provider_id with
  | None -> None
  | Some binding ->
    let contexts = entries |> List.filter_map (fun (entry:Llm_provider.Model_catalog.model_entry) ->
      let provider = match entry.provider_name with
        | Some name -> name=binding.id || List.mem name binding.aliases
        | None -> false in
      let exact = entry.id_prefix=model || Option.fold ~none:false ~some:(List.mem model) entry.supported_models in
      match entry.max_context_tokens with
      | Some context when provider && exact && context>0 -> Some context
      | _ -> None) |> List.sort_uniq Int.compare in
    match contexts with [context] -> Some context | _ -> None
