module Msp = Runtime_muse_msp

let optional_json encode = function None -> `Null | Some value -> encode value

let to_json (catalog : Msp.model_catalog) =
  let models = List.map (fun (model : Msp.model_catalog_entry) ->
    `Assoc
      [ "id", `String model.model_id
      ; "label", `String model.display_label
      ; "provider_id", `String model.provider_id
      ; "profile_id", optional_json (fun value -> `String value) model.profile_id
      ; "context", optional_json (fun value -> `Int value) model.context_limit
      ; "output_limit", optional_json (fun value -> `Int value) model.output_limit
      ; "is_default", `Bool model.is_default
      ; "reasoning_effort_variants", (match model.variants with
        | Msp.Unknown_efforts -> `String "unknown"
        | Msp.Known_efforts efforts ->
          `List (List.map (fun effort -> `String (Msp.reasoning_effort_to_string effort)) efforts))
      ]) catalog.models in
  `Assoc
    [ "schema", `String "masc.muse_models.v1"
    ; "source", `String (Msp.model_catalog_source_to_string catalog.source)
    ; "provider_id", `String catalog.provider_id
    ; "profile_id", optional_json (fun value -> `String value) catalog.profile_id
    ; "account_availability_verified", `Bool false
    ; "invocation_verified", `Bool false
    ; "models", `List models
    ]
;;

let run ~mgr ~clock ~cwd ~account_home ~cli_path ~timeout_s =
  let config = { (Runtime_muse_serve.default_config ()) with
    cli_path; account_home = Some account_home;
    admission_timeout_s = timeout_s; timeout_s = Some timeout_s } in
  Runtime_muse_serve.list_models ~mgr ~clock ~cwd config |> Result.map to_json
;;
