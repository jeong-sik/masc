let provider_prefix_of_label label =
  let normalized = String.trim label in
  match String.index_opt normalized ':' with
  | Some idx when idx > 0 ->
      Some (String.sub normalized 0 idx |> String.trim |> String.lowercase_ascii)
  | _ -> None

let provider_prefix_of_label_result label =
  match provider_prefix_of_label label with
  | Some provider -> Ok provider
  | None ->
      Error
        (Printf.sprintf
           "Runtime model label must be provider:model, got: %s"
           (String.trim label))

let provider_model_parts_result label =
  let normalized = String.trim label in
  match String.index_opt normalized ':' with
  | Some idx when idx > 0 && idx < String.length normalized - 1 ->
      let provider =
        String.sub normalized 0 idx |> String.trim |> String.lowercase_ascii
      in
      let model_id =
        String.sub normalized (idx + 1) (String.length normalized - idx - 1)
        |> String.trim
      in
      if String.equal model_id "" then
        Error
          (Printf.sprintf "Runtime model label must include a model id, got: %s"
             normalized)
      else Ok (provider, model_id)
  | _ ->
      Error
        (Printf.sprintf "Runtime model label must be provider:model, got: %s"
           normalized)

let model_id_of_label_result label =
  match provider_model_parts_result label with
  | Ok (_, model_id) -> Ok model_id
  | Error _ as err -> err
