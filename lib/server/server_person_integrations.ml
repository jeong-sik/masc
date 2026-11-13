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

(* The posture a call of the client starts with, by the name its default
   configuration reads: a verification starts each client with that
   configuration, and the preview Keeper turn starts Claude Code and Codex
   the same way. *)
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

(* A binding makes its Runtime from the model row it names, as a Runtime is
   materialized; a binding of no declared row makes none. A model row that
   declares no tool calling is not offered: the verification refuses it
   before any client starts. *)
let models (config : Runtime_schema.config) provider_id =
  List.filter_map
    (fun (binding : Runtime_schema.binding) ->
      if not (String.equal binding.provider_id provider_id)
      then None
      else (
        match Runtime_schema.model_of_id config binding.model_id with
        | None -> None
        | Some model ->
          (match Runtime_verification.model_refusal model with
           | Some (_ : Runtime_verification.unavailable) -> None
           | None -> Some binding.model_id)))
    config.bindings
;;

let of_config (config : Runtime_schema.config) =
  List.filter_map
    (fun (provider : Runtime_schema.provider) ->
      match Server_setup_account_login.person_target config ~integration_id:provider.id with
      | Error (_ : Server_setup_account_login.person_refusal) -> None
      | Ok { Server_runtime_setup_actions.client; cli_path = _; spawn_path = _ } ->
        Some
          { integration_id = provider.id
          ; display_name = provider.display_name
          ; models = models config provider.id
          ; calls = calls_of client
          })
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
