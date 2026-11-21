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
  ; takes_login : bool
  ; takes_key : bool
  }

(* The posture a call of the client starts with, by the name its default
   configuration reads: a verification starts each client with that
   configuration, and the preview Keeper turn starts Claude Code and Codex
   the same way. *)
let call_posture : Client.client -> Runtime_native_tools.posture = function
  | Client.Claude -> Runtime_native_tools.claude_code_default
  | Client.Codex -> Runtime_native_tools.codex_default
  | Client.Antigravity -> Runtime_native_tools.antigravity_default
;;

let calls_of client =
  match Runtime_account_access.authorize_native (call_posture client) with
  | Ok () -> Allowed
  | Error refusal -> Refused refusal
;;

(* Official-client rows declare tool support directly on [model_spec].
   HTTP [Agent_core] rows resolve tool support via {!Runtime_adapter.http_model_declares_tools}
   so catalog rows are never overridden by TOML defaults. *)
let official_verdict (config : Runtime_schema.config) (binding : Runtime_schema.binding) =
  match Runtime_schema.model_of_id config binding.model_id with
  | None -> Error Model_undeclared
  | Some model ->
    (match Runtime_verification.model_refusal model with
     | Some unavailable -> Error (Model_refused unavailable)
     | None -> Ok ())
;;

let http_verdict
      (config : Runtime_schema.config)
      (provider : Runtime_schema.provider)
      (binding : Runtime_schema.binding)
  =
  match Runtime_schema.model_of_id config binding.model_id with
  | None -> Error Model_undeclared
  | Some model ->
    (match Runtime_adapter.http_model_declares_tools provider model with
     | Ok true -> Ok ()
     | Ok false | Error (_ : string) ->
       (* Fail closed: if provider/catalog resolution rejects the declaration,
          never fall back to trusting bare TOML tools-support. *)
       Error (Model_refused Runtime_verification.Tools_not_declared))
;;

(* The bindings of the provider in declared order, each on the side its
   verdict puts it: the models a person may name, and the others with why. *)
let models_and_withheld_by ~verdict (config : Runtime_schema.config) provider_id =
  config.bindings
  |> List.filter (fun (binding : Runtime_schema.binding) ->
    String.equal binding.provider_id provider_id)
  |> List.partition_map (fun (binding : Runtime_schema.binding) ->
    match verdict binding with
    | Ok () -> Either.Left binding.model_id
    | Error why -> Either.Right (binding.model_id, why))
;;

let of_config (config : Runtime_schema.config) =
  List.filter_map
    (fun (provider : Runtime_schema.provider) ->
      if Server_key_account.http_takes_key provider
      then
        let models, withheld =
          models_and_withheld_by ~verdict:(http_verdict config provider) config provider.id
        in
        Some
          { integration_id = provider.id
          ; display_name = provider.display_name
          ; models
          ; withheld
          ; calls = Allowed
          ; takes_login = false
          ; takes_key = true
          }
      else
        (match Server_setup_account_login.person_target config ~integration_id:provider.id with
         | Error (_ : Server_setup_account_login.person_refusal) -> None
         | Ok { Server_runtime_setup_actions.client; cli_path = _; spawn_path = _ } ->
           let models, withheld =
             models_and_withheld_by ~verdict:(official_verdict config) config provider.id
           in
           Some
             { integration_id = provider.id
             ; display_name = provider.display_name
             ; models
             ; withheld
             ; calls = calls_of client
             ; takes_login = true
             ; takes_key = Server_key_account.takes_key client
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

let connect_json ~takes_login ~takes_key =
  let entries =
    (if takes_login then [ `String "login" ] else [])
    @ (if takes_key then [ `String "key" ] else [])
  in
  `List entries
;;

let integration_json { integration_id; display_name; models; withheld; calls; takes_login; takes_key } =
  `Assoc
    ([ "integration_id", `String integration_id
     ; "display_name", `String display_name
     ; "connect", connect_json ~takes_login ~takes_key
     ; "models", `List (List.map (fun model -> `String model) models)
     ; "withheld", `List (List.map withheld_json withheld)
     ]
     @ calls_fields calls)
;;

type start_note =
  | Access_unpublished
  | No_person_provider
  | No_model of
      { integration_id : string
      ; withheld : (string * withheld) list
      }

(* A provider whose calls are refused for its tools gets no note: a model of
   it would still not be called here. Before the publication every provider
   reads as refused, and that is one note of its own, not the silence of a
   table where every provider offers a model. *)
let start_notes = function
  | [] -> [ No_person_provider ]
  | _ :: _ as integrations ->
    let notes =
      List.filter_map
        (fun { integration_id
             ; display_name = (_ : string)
             ; models
             ; withheld
             ; calls
             ; takes_login = (_ : bool)
             ; takes_key = (_ : bool)
             } ->
          match calls, models with
          | Refused Runtime_account_access.Native_unpublished, (_ : string list) ->
            Some Access_unpublished
          | Allowed, [] -> Some (No_model { integration_id; withheld })
          | Allowed, _ :: _ -> None
          | ( Refused
                Runtime_account_access.(
                  ( Native_tools_reach_other_homes (_ : Runtime_native_tools.posture)
                  | Native_tools_reach_person_homes (_ : Runtime_native_tools.posture)
                  | Person_homes_unread
                      { posture = (_ : Runtime_native_tools.posture); unread = (_ : Unix.error) } ))
            , (_ : string list) ) -> None)
        integrations
    in
    if List.mem Access_unpublished notes then [ Access_unpublished ] else notes
;;

let start_note_to_string = function
  | Access_unpublished ->
    "what people may connect was read before this process published its access, so which \
     provider offers people a model is not known"
  | No_person_provider ->
    "runtime.toml declares no provider that a person signs in to, so people can connect nothing"
  | No_model { integration_id; withheld = [] } ->
    Printf.sprintf
      "%s offers people no model: runtime.toml declares no binding of it"
      integration_id
  | No_model { integration_id; withheld = _ :: _ as withheld } ->
    Printf.sprintf
      "%s offers people no model: %s"
      integration_id
      (String.concat
         ", "
         (List.map
            (fun (model, why) -> Printf.sprintf "%s (%s)" model (withheld_code why))
            withheld))
;;

(* [Server_runtime_setup_actions.config] writes a file it cannot read to the
   log itself, so that failure has no line here. It gives no other error;
   one that it came to give would be said here. [of_config] finds the command
   of each provider, which reads the working directory for a relative one
   ([Runtime_official_cli_install]): with that directory gone it raises, and
   a start says so and goes on. *)
let start_lines ~base_path =
  match Server_runtime_setup_actions.config ~base_path with
  | Ok config ->
    (match of_config config with
     | integrations -> List.map start_note_to_string (start_notes integrations)
     | exception Sys_error reason ->
       [ Printf.sprintf "what people may connect was not read at this start: %s" reason ])
  | Error
      Server_runtime_setup_actions.(
        Configuration_unavailable
          (Unreadable (_ : string) | Unparsable (_ : Runtime_toml.parse_error list))) -> []
  | Error
      (Server_runtime_setup_actions.(
         ( Invalid_request
         | Network_unavailable
         | Unsupported_connection
         | Disabled_connection
         | Credential_unavailable
         | Discovery_failed (_ : Runtime_model_discovery.error)
         | Save_failed (_ : Runtime_setup_batch.error)
         | Account_refused (_ : Runtime_account_access.refusal) )) as error) ->
    [ Printf.sprintf
        "runtime.toml was not read for what people may connect: %s"
        (Server_runtime_setup_actions.error_message error)
    ]
;;

let path = "/api/v1/auth/integrations"

let answer ~base_path =
  match Server_runtime_setup_actions.config ~base_path with
  | Error error ->
    R.json R.Service_unavailable_503 [ "error", `String (Server_runtime_setup_actions.error_message error) ]
  | Ok config -> R.json R.Ok_200 [ "integrations", `List (List.map integration_json (of_config config)) ]
;;
