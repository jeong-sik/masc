(** Execution labels require explicit operator choices or catalog defaults. *)
module Runtime_binding = Agent_core.Provider_runtime_binding

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))
;;

let configured_default_model_label_result () =
  match Sys.getenv_opt "MASC_DEFAULT_RUNTIME" with
  | Some raw ->
    let labels = split_csv_nonempty raw in
    (match labels with
     | first :: _ -> Ok (Some first)
     | [] -> Error "MASC_DEFAULT_RUNTIME is set but empty")
  | None ->
    (match Sys.getenv_opt "MASC_DEFAULT_PROVIDER", Sys.getenv_opt "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id ->
       (match String_util.trim_nonempty provider, String_util.trim_nonempty model_id with
        | Some provider, Some model_id -> Ok (Some (provider ^ ":" ^ model_id))
        | None, _ | _, None -> Error "Explicit provider and model must be nonempty")
     | Some _, None ->
       Error "MASC_DEFAULT_MODEL is required when MASC_DEFAULT_PROVIDER is set"
     | None, Some _ ->
       Error "MASC_DEFAULT_PROVIDER is required when MASC_DEFAULT_MODEL is set"
     | None, None -> Ok None)
;;


let binding_auth_available (binding : Runtime_binding.t) =
  match binding.auth with
  | No_auth -> true
  | Api_key | Setup_token -> binding.available
;;

let default_execution_model_strings _runtime_id =
  match configured_default_model_label_result () with
  | Error _ -> []
  | Ok explicit ->
    let defaults = Runtime_binding.all () |> List.filter_map (fun binding ->
      if not (binding_auth_available binding) then None
      else Option.map (fun model -> binding.id ^ ":" ^ model)
        (Option.bind binding.default_model String_util.trim_nonempty)) in
    Json_util.dedupe_keep_order (Option.to_list explicit @ defaults)
;;
