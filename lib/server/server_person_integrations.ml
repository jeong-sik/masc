module R = Login_routes
module Client = Runtime_setup_login_client

type calls =
  | Allowed
  | Refused of Runtime_account_access.native_refusal

type integration =
  { integration_id : string
  ; display_name : string
  ; models : string list
  ; calls : calls
  }

(* The posture a call of the client starts with: the default configuration of
   Claude Code and of Codex, which a verification and a Keeper turn both
   start from, and the read posture that a verification of Muse sets, which
   is its default too. *)
let call_posture : Client.client -> Runtime_native_tools.posture = function
  | Client.Claude -> Runtime_native_tools.claude_code_default
  | Client.Codex -> Runtime_native_tools.codex_default
  | Client.Muse -> Runtime_native_tools.muse_default
  | Client.Antigravity -> Runtime_native_tools.antigravity_default
;;

let calls_of client =
  match Runtime_account_access.authorize_native (call_posture client) with
  | Ok () -> Allowed
  | Error refusal -> Refused refusal
;;

let models (config : Runtime_schema.config) provider_id =
  List.filter_map
    (fun (binding : Runtime_schema.binding) ->
      if String.equal binding.provider_id provider_id then Some binding.model_id else None)
    config.bindings
;;

let of_config (config : Runtime_schema.config) =
  List.filter_map
    (fun (provider : Runtime_schema.provider) ->
      match Server_runtime_setup_actions.login_target_of_config config ~integration_id:provider.id with
      | Error (_ : Server_runtime_setup_actions.error) -> None
      | Ok { Server_runtime_setup_actions.client; cli_path = _; spawn_path = _ } ->
        (match Server_setup_account_login.person_may_connect client with
         | Error (_ : string) -> None
         | Ok () ->
           Some
             { integration_id = provider.id
             ; display_name = provider.display_name
             ; models = models config provider.id
             ; calls = calls_of client
             }))
    config.providers
;;

let refusal_code : Runtime_account_access.native_refusal -> string = function
  | Runtime_account_access.Native_unpublished -> "native_unpublished"
  | Runtime_account_access.Native_tools_reach_other_homes (_ : Runtime_native_tools.posture) ->
    "native_tools_reach_other_homes"
  | Runtime_account_access.Native_tools_reach_person_homes (_ : Runtime_native_tools.posture) ->
    "native_tools_reach_person_homes"
  | Runtime_account_access.Person_homes_unread _ -> "person_homes_unread"
;;

let calls_fields = function
  | Allowed -> [ "calls", `String "allowed" ]
  | Refused refusal -> [ "calls", `String "refused"; "refusal", `String (refusal_code refusal) ]
;;

let integration_json { integration_id; display_name; models; calls } =
  `Assoc
    ([ "integration_id", `String integration_id
     ; "display_name", `String display_name
     ; "models", `List (List.map (fun model -> `String model) models)
     ]
     @ calls_fields calls)
;;

let path = "/api/v1/auth/integrations"

let answer ~base_path =
  match Server_runtime_setup_actions.config ~base_path with
  | Error error ->
    R.json R.Service_unavailable_503 [ "error", `String (Server_runtime_setup_actions.error_message error) ]
  | Ok config -> R.json R.Ok_200 [ "integrations", `List (List.map integration_json (of_config config)) ]
;;
