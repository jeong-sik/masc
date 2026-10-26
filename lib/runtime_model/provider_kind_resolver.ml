(** Sum-typed provider-kind resolver inside the runtime/AGENT_CORE boundary.
    See .mli for the contract. *)

type resolution =
  | Registered of
      { binding : Agent_core.Provider_runtime_binding.t
      ; model_id : string
      }
  | Custom_url of { model_id : string; base_url : string }
  | Unknown of string

let resolve (spec : string) : resolution =
  let s = String.trim spec in
  match Runtime_model_id_split.split_provider_model s with
  | None ->
    Unknown
      (Printf.sprintf
         "malformed spec %S: expected \"provider:model\" or \"custom:model@url\""
         spec)
  | Some ("custom", rest) ->
    (match Runtime_model_resolve.parse_custom_model rest with
     | Ok (model_id, base_url) -> Custom_url { model_id; base_url }
     | Error error -> Unknown (Runtime_model_resolve.custom_model_error_to_string error))
  | Some (provider_name, model_id) ->
    (match Agent_core.Provider_runtime_binding.find provider_name with
     | Some binding -> Registered { binding; model_id }
     | None -> Unknown (Printf.sprintf "unknown provider %S in spec %S" provider_name spec))
