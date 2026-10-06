type error = Validation of string | Persistence of string
type applied =
  { message : string
  ; curator_refresh : Server_workspace_memory_curator.refresh option
  }

let apply ~base_path request =
  let key = Server_prompt_override_request.key request in
  let appraisal_prompt = List.mem key
    [Prompt_names.candle_appraiser_grade;Prompt_names.candle_appraiser_relation;
     Prompt_names.candle_appraiser_weights] in
  let before = if appraisal_prompt then Some (Prompt_registry.resolve_prompt key) else None in
  let notify_changed () = match before with
    | None -> ()
    | Some resolution ->
        let override_value = Prompt_registry.override_entries ()
          |> List.find_opt (fun (entry : Prompt_override_persistence.entry) -> entry.key = key)
          |> Option.map (fun entry -> entry.Prompt_override_persistence.value) in
        let _, effective = Prompt_registry_types.resolve_source
          ~override_value ~file_value:resolution.file_value in
        if effective <> resolution.effective then Candle_payout_worker.wake () in
  Eio_guard.protect ~finally:notify_changed (fun () ->
  let persisted = match request with
    | Server_prompt_override_request.Clear _ ->
      Prompt_registry.clear_prompt_override_persisted ~base_path key
      |> Result.map (fun () -> "override cleared")
      |> Result.map_error (fun message -> Persistence message)
    | Server_prompt_override_request.Set { value; _ } ->
      Prompt_registry.set_override_persisted ~base_path key value
      |> Result.map (fun () -> "override set")
      |> Result.map_error (function
        | Prompt_registry.Validation_error message -> Validation message
        | Prompt_registry.Persistence_error message -> Persistence message) in
  Result.map (fun message ->
    let curator_refresh =
      if String.equal key Prompt_names.workspace_memory_curator
      then Some (Server_workspace_memory_curator.request ~base_path)
      else None in
    { message; curator_refresh }) persisted)

let refresh_json = function
  | None -> `Null
  | Some Server_workspace_memory_curator.Queued -> `Assoc ["status", `String "queued"]
  | Some Server_workspace_memory_curator.No_owner -> `Assoc ["status", `String "no_owner"]
  | Some (Server_workspace_memory_curator.Unavailable detail) ->
    `Assoc ["status", `String "unavailable"; "detail", `String detail]
