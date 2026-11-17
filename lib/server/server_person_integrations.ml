module R = Login_routes
module Client = Runtime_setup_login_client

type calls =
  | Allowed
  | Refused of Runtime_account_access.native_refusal

type withheld =
  | Model_undeclared
  | Model_refused of Runtime_verification.unavailable

type integration =
  { integration_id : string
  ; display_name : string
  ; models : string list
  ; withheld : (string * withheld) list
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
let verdict (config : Runtime_schema.config) (binding : Runtime_schema.binding) =
  match Runtime_schema.model_of_id config binding.model_id with
  | None -> Error Model_undeclared
  | Some model ->
    (match Runtime_verification.model_refusal model with
     | Some unavailable -> Error (Model_refused unavailable)
     | None -> Ok ())
;;

(* The bindings of the provider in declared order, each on the side its
   verdict puts it: the models a person may name, and the others with why. *)
let models_and_withheld (config : Runtime_schema.config) provider_id =
  config.bindings
  |> List.filter (fun (binding : Runtime_schema.binding) ->
    String.equal binding.provider_id provider_id)
  |> List.partition_map (fun (binding : Runtime_schema.binding) ->
    match verdict config binding with
    | Ok () -> Either.Left binding.model_id
    | Error why -> Either.Right (binding.model_id, why))
;;

let of_config (config : Runtime_schema.config) =
  List.filter_map
    (fun (provider : Runtime_schema.provider) ->
      match Server_setup_account_login.person_target config ~integration_id:provider.id with
      | Error (_ : Server_setup_account_login.person_refusal) -> None
      | Ok { Server_runtime_setup_actions.client; cli_path = _; spawn_path = _ } ->
        let models, withheld = models_and_withheld config provider.id in
        Some
          { integration_id = provider.id
          ; display_name = provider.display_name
          ; models
          ; withheld
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

(* A refused row has the code its verification answers with
   ([Runtime_verification.failure_code]); a binding of no row has no
   verification to name it. *)
let withheld_code = function
  | Model_undeclared -> "model_undeclared"
  | Model_refused unavailable ->
    Runtime_verification.failure_code (Runtime_verification.Unavailable unavailable)
;;

let withheld_json (model, why) =
  `Assoc [ "model", `String model; "reason", `String (withheld_code why) ]
;;

let integration_json { integration_id; display_name; models; withheld; calls } =
  `Assoc
    ([ "integration_id", `String integration_id
     ; "display_name", `String display_name
     ; "models", `List (List.map (fun model -> `String model) models)
     ; "withheld", `List (List.map withheld_json withheld)
     ]
     @ calls_fields calls)
;;

let start_notes = function
  | [] ->
    [ "runtime.toml declares no provider that a person signs in to, so people can connect \
       nothing"
    ]
  | _ :: _ as integrations ->
    List.filter_map
      (fun { integration_id; display_name = (_ : string); models; withheld; calls = (_ : calls) } ->
        match models, withheld with
        | _ :: _, (_ : (string * withheld) list) -> None
        | [], [] ->
          Some
            (Printf.sprintf
               "%s offers people no model: runtime.toml declares no binding of it"
               integration_id)
        | [], _ :: _ ->
          Some
            (Printf.sprintf
               "%s offers people no model: %s"
               integration_id
               (String.concat
                  ", "
                  (List.map
                     (fun (model, why) -> Printf.sprintf "%s (%s)" model (withheld_code why))
                     withheld))))
      integrations
;;

let path = "/api/v1/auth/integrations"

let answer ~base_path =
  match Server_runtime_setup_actions.config ~base_path with
  | Error error ->
    R.json R.Service_unavailable_503 [ "error", `String (Server_runtime_setup_actions.error_message error) ]
  | Ok config -> R.json R.Ok_200 [ "integrations", `List (List.map integration_json (of_config config)) ]
;;
