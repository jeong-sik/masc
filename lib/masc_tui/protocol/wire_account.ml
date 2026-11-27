open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let auth_provider_accounts_path = "/api/v1/auth/provider-accounts"
let auth_integrations_path = "/api/v1/auth/integrations"
let setup_accounts_verify_path = "/api/v1/setup/accounts/verify"
let setup_accounts_key_path = "/api/v1/setup/accounts/key"

let setup_accounts_key_entry_path ~provider_account_id =
  "/api/v1/setup/accounts/key/" ^ percent_encode (String.trim provider_account_id)

let setup_accounts_login_cancel_path ~login_id =
  "/api/v1/setup/accounts/login/" ^ percent_encode (String.trim login_id) ^ "/cancel"

let assoc_member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let require_object ~context = function
  | `Assoc _ as obj -> Ok obj
  | bad -> field_type_error context "an object" bad

let required_object_field json key =
  let* value = required_member json key in
  match value with
  | `Assoc _ as obj -> Ok obj
  | bad -> field_type_error key "an object" bad

let required_nullable_object_field json key =
  let* value = required_member json key in
  match value with
  | `Null -> Ok None
  | `Assoc _ as obj -> Ok (Some obj)
  | bad -> field_type_error key "an object or null" bad

let required_bool_field json key =
  let* value = required_member json key in
  match value with
  | `Bool b -> Ok b
  | bad -> field_type_error key "a boolean" bad

let required_nullable_nonblank_string json key =
  let* value = required_member json key in
  match value with
  | `Null -> Ok None
  | `String s ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then
        Error (Printf.sprintf "field %S must not be blank" key)
      else Ok (Some trimmed)
  | bad -> field_type_error key "a string or null" bad

(* ---- Provider Accounts & Runtimes ---- *)

type provider_key_state =
  | Key_readable
  | Key_missing
  | Key_unreadable
  | Key_not_looked_at

let provider_key_state_rank = function
  | Key_readable -> 0
  | Key_missing -> 1
  | Key_unreadable -> 2
  | Key_not_looked_at -> 3

let equal_provider_key_state a b =
  Int.equal (provider_key_state_rank a) (provider_key_state_rank b)

let provider_key_state_to_string = function
  | Key_readable -> "readable"
  | Key_missing -> "key_missing"
  | Key_unreadable -> "key_unreadable"
  | Key_not_looked_at -> "not_looked_at"

let provider_key_state_of_string = function
  | "readable" -> Ok Key_readable
  | "key_missing" -> Ok Key_missing
  | "key_unreadable" -> Ok Key_unreadable
  | "not_looked_at" -> Ok Key_not_looked_at
  | other -> Error (Printf.sprintf "unknown provider key state %S" other)

type provider_account_kind =
  | Provider_login
  | Provider_key of provider_key_state

let equal_provider_account_kind a b =
  match (a, b) with
  | Provider_login, Provider_login -> true
  | Provider_key x, Provider_key y -> equal_provider_key_state x y
  | Provider_login, Provider_key _ | Provider_key _, Provider_login -> false

type provider_removal_state =
  | Removal_start_given_up
  | Removal_key_not_removed
  | Removal_home_not_removed

let provider_removal_state_rank = function
  | Removal_start_given_up -> 0
  | Removal_key_not_removed -> 1
  | Removal_home_not_removed -> 2

let equal_provider_removal_state a b =
  Int.equal (provider_removal_state_rank a) (provider_removal_state_rank b)

let provider_removal_state_to_string = function
  | Removal_start_given_up -> "start_given_up"
  | Removal_key_not_removed -> "key_not_removed"
  | Removal_home_not_removed -> "home_not_removed"

let provider_removal_state_of_string = function
  | "start_given_up" -> Ok Removal_start_given_up
  | "key_not_removed" -> Ok Removal_key_not_removed
  | "home_not_removed" -> Ok Removal_home_not_removed
  | other -> Error (Printf.sprintf "unknown provider removal state %S" other)

type provider_replacement_state =
  | Replacement_start_given_up

let equal_provider_replacement_state a b =
  match (a, b) with
  | Replacement_start_given_up, Replacement_start_given_up -> true

let provider_replacement_state_to_string = function
  | Replacement_start_given_up -> "start_given_up"

let provider_replacement_state_of_string = function
  | "start_given_up" -> Ok Replacement_start_given_up
  | other -> Error (Printf.sprintf "unknown provider replacement state %S" other)

type provider_account = {
  provider_account_id : string;
  integration_id : string;
  kind : provider_account_kind;
  removal : provider_removal_state option;
  replacement : provider_replacement_state option;
}

type runtime_unread_reason =
  | Unread_configuration_unavailable
  | Unread_template_not_declared
  | Unread_model_not_bound
  | Unread_runtime_not_bound
  | Unread_not_materialized
  | Unread_key_missing
  | Unread_key_unreadable

let runtime_unread_reason_rank = function
  | Unread_configuration_unavailable -> 0
  | Unread_template_not_declared -> 1
  | Unread_model_not_bound -> 2
  | Unread_runtime_not_bound -> 3
  | Unread_not_materialized -> 4
  | Unread_key_missing -> 5
  | Unread_key_unreadable -> 6

let equal_runtime_unread_reason a b =
  Int.equal (runtime_unread_reason_rank a) (runtime_unread_reason_rank b)

let runtime_unread_reason_to_string = function
  | Unread_configuration_unavailable -> "configuration_unavailable"
  | Unread_template_not_declared -> "template_not_declared"
  | Unread_model_not_bound -> "model_not_bound"
  | Unread_runtime_not_bound -> "runtime_not_bound"
  | Unread_not_materialized -> "not_materialized"
  | Unread_key_missing -> "key_missing"
  | Unread_key_unreadable -> "key_unreadable"

let runtime_unread_reason_of_string = function
  | "configuration_unavailable" -> Ok Unread_configuration_unavailable
  | "template_not_declared" -> Ok Unread_template_not_declared
  | "model_not_bound" -> Ok Unread_model_not_bound
  | "runtime_not_bound" -> Ok Unread_runtime_not_bound
  | "not_materialized" -> Ok Unread_not_materialized
  | "key_missing" -> Ok Unread_key_missing
  | "key_unreadable" -> Ok Unread_key_unreadable
  | other -> Error (Printf.sprintf "unknown runtime unread reason %S" other)

type provider_runtime_model =
  | Runtime_model of string
  | Runtime_model_unread of runtime_unread_reason

type provider_runtime = {
  runtime_id : string;
  provider_account_id : string;
  model : provider_runtime_model;
}

type provider_accounts_snapshot = {
  provider_accounts : provider_account list;
  runtimes : provider_runtime list;
}

let decode_provider_account json =
  let* obj = require_object ~context:"provider_account" json in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* integration_id = required_nonblank_string obj "integration_id" in
  let* kind_raw = required_nonblank_string obj "kind" in
  let* kind =
    match kind_raw with
    | "login" -> (
        match assoc_member_opt "key" obj with
        | None | Some `Null -> Ok Provider_login
        | Some _ ->
            Error "provider_account with kind=\"login\" must not carry a \"key\" field")
    | "key" ->
        let* key_raw = required_nonblank_string obj "key" in
        let* key_state = provider_key_state_of_string key_raw in
        Ok (Provider_key key_state)
    | other -> Error (Printf.sprintf "unknown provider_account kind %S" other)
  in
  let* removal =
    match assoc_member_opt "removal" obj with
    | None | Some `Null -> Ok None
    | Some (`String s) ->
        let* st = provider_removal_state_of_string (String.trim s) in
        Ok (Some st)
    | Some bad -> field_type_error "removal" "a string" bad
  in
  let* replacement =
    match assoc_member_opt "replacement" obj with
    | None | Some `Null -> Ok None
    | Some (`String s) ->
        let* st = provider_replacement_state_of_string (String.trim s) in
        Ok (Some st)
    | Some bad -> field_type_error "replacement" "a string" bad
  in
  Ok { provider_account_id; integration_id; kind; removal; replacement }

let decode_provider_runtime json =
  let* obj = require_object ~context:"provider_runtime" json in
  let* runtime_id = required_nonblank_string obj "runtime_id" in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* model_opt = required_nullable_nonblank_string obj "model" in
  let* model =
    match model_opt with
    | Some m -> (
        match assoc_member_opt "unread" obj with
        | None | Some `Null -> Ok (Runtime_model m)
        | Some _ ->
            Error
              "provider_runtime with non-null model must not carry \"unread\"")
    | None ->
        let* unread_raw = required_nonblank_string obj "unread" in
        let* reason = runtime_unread_reason_of_string unread_raw in
        Ok (Runtime_model_unread reason)
  in
  Ok { runtime_id; provider_account_id; model }

let decode_provider_accounts_snapshot json =
  let* obj = require_object ~context:auth_provider_accounts_path json in
  let* account_items = required_list_field obj "provider_accounts" in
  let* provider_accounts =
    decode_list "provider_accounts" decode_provider_account account_items
  in
  let* runtime_items = required_list_field obj "runtimes" in
  let* runtimes = decode_list "runtimes" decode_provider_runtime runtime_items in
  Ok { provider_accounts; runtimes }

(* ---- Person Integrations ---- *)

type connect_method =
  | Connect_login
  | Connect_key

let equal_connect_method a b =
  match (a, b) with
  | Connect_login, Connect_login | Connect_key, Connect_key -> true
  | Connect_login, Connect_key | Connect_key, Connect_login -> false

let connect_method_to_string = function
  | Connect_login -> "login"
  | Connect_key -> "key"

let decode_connect_method = function
  | `String "login" -> Ok Connect_login
  | `String "key" -> Ok Connect_key
  | `String other -> Error (Printf.sprintf "unknown connect method %S" other)
  | bad -> field_type_error "connect" "a string (\"login\" or \"key\")" bad

type withheld_model = {
  model : string;
  reason : string;
}

type integration_refusal =
  | Refusal_native_unpublished
  | Refusal_native_tools_reach_other_homes
  | Refusal_native_tools_reach_person_homes
  | Refusal_person_homes_unread

let integration_refusal_rank = function
  | Refusal_native_unpublished -> 0
  | Refusal_native_tools_reach_other_homes -> 1
  | Refusal_native_tools_reach_person_homes -> 2
  | Refusal_person_homes_unread -> 3

let equal_integration_refusal a b =
  Int.equal (integration_refusal_rank a) (integration_refusal_rank b)

let integration_refusal_to_string = function
  | Refusal_native_unpublished -> "native_unpublished"
  | Refusal_native_tools_reach_other_homes -> "native_tools_reach_other_homes"
  | Refusal_native_tools_reach_person_homes -> "native_tools_reach_person_homes"
  | Refusal_person_homes_unread -> "person_homes_unread"

let integration_refusal_of_string = function
  | "native_unpublished" -> Ok Refusal_native_unpublished
  | "native_tools_reach_other_homes" ->
      Ok Refusal_native_tools_reach_other_homes
  | "native_tools_reach_person_homes" ->
      Ok Refusal_native_tools_reach_person_homes
  | "person_homes_unread" -> Ok Refusal_person_homes_unread
  | other -> Error (Printf.sprintf "unknown integration refusal %S" other)

type integration_calls =
  | Calls_allowed
  | Calls_refused of integration_refusal

type person_integration = {
  integration_id : string;
  display_name : string;
  connect : connect_method list;
  models : string list;
  withheld : withheld_model list;
  calls : integration_calls;
}

type person_integrations_snapshot = {
  integrations : person_integration list;
}

let decode_withheld_model json =
  let* obj = require_object ~context:"withheld" json in
  let* model = required_nonblank_string obj "model" in
  let* reason = required_nonblank_string obj "reason" in
  Ok { model; reason }

let decode_nonblank_string_item ~field = function
  | `String s ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then
        Error (Printf.sprintf "%s element must not be blank" field)
      else Ok trimmed
  | bad -> field_type_error field "a string" bad

let decode_person_integration json =
  let* obj = require_object ~context:"integration" json in
  let* integration_id = required_nonblank_string obj "integration_id" in
  let* display_name = required_nonblank_string obj "display_name" in
  let* connect_items = required_list_field obj "connect" in
  let* connect = decode_list "connect" decode_connect_method connect_items in
  let* model_items = required_list_field obj "models" in
  let* models =
    decode_list "models" (decode_nonblank_string_item ~field:"models") model_items
  in
  let* withheld_items = required_list_field obj "withheld" in
  let* withheld = decode_list "withheld" decode_withheld_model withheld_items in
  let* calls_raw = required_nonblank_string obj "calls" in
  let* calls =
    match calls_raw with
    | "allowed" -> (
        match assoc_member_opt "refusal" obj with
        | None | Some `Null -> Ok Calls_allowed
        | Some _ ->
            Error
              "integration with calls=\"allowed\" must not carry \"refusal\"")
    | "refused" ->
        let* refusal_raw = required_nonblank_string obj "refusal" in
        let* refusal = integration_refusal_of_string refusal_raw in
        Ok (Calls_refused refusal)
    | other -> Error (Printf.sprintf "unknown integration calls %S" other)
  in
  Ok { integration_id; display_name; connect; models; withheld; calls }

let decode_person_integrations_snapshot json =
  let* obj = require_object ~context:auth_integrations_path json in
  let* items = required_list_field obj "integrations" in
  let* integrations =
    decode_list "integrations" decode_person_integration items
  in
  Ok { integrations }

(* ---- Verification ([POST /api/v1/setup/accounts/verify]) ---- *)

type verification_status =
  | Verify_verified
  | Verify_failed
  | Verify_unavailable

let verification_status_rank = function
  | Verify_verified -> 0
  | Verify_failed -> 1
  | Verify_unavailable -> 2

let equal_verification_status a b =
  Int.equal (verification_status_rank a) (verification_status_rank b)

let verification_status_to_string = function
  | Verify_verified -> "verified"
  | Verify_failed -> "failed"
  | Verify_unavailable -> "unavailable"

let verification_status_of_string = function
  | "verified" -> Ok Verify_verified
  | "failed" -> Ok Verify_failed
  | "unavailable" -> Ok Verify_unavailable
  | other -> Error (Printf.sprintf "unknown verification status %S" other)

type verification_checks = {
  response : bool;
  tool_called : bool;
  tool_roundtrip : bool;
}

type verification_failure = {
  code : string;
  message : string;
  detail : string option;
}

type verification_result = {
  schema : string;
  runtime_id : string;
  model : string option;
  observed_model : string option;
  status : verification_status;
  checks : verification_checks;
  failure : verification_failure option;
}

type runtime_record_outcome =
  | Runtime_made
  | Runtime_existing

let equal_runtime_record_outcome a b =
  match (a, b) with
  | Runtime_made, Runtime_made | Runtime_existing, Runtime_existing -> true
  | Runtime_made, Runtime_existing | Runtime_existing, Runtime_made -> false

let runtime_record_outcome_to_string = function
  | Runtime_made -> "made"
  | Runtime_existing -> "existing"

let runtime_record_outcome_of_string = function
  | "made" -> Ok Runtime_made
  | "existing" -> Ok Runtime_existing
  | other -> Error (Printf.sprintf "unknown runtime record outcome %S" other)

type verified_runtime = {
  runtime_id : string;
  record : runtime_record_outcome;
}

type account_verify_response = {
  verification : verification_result;
  runtime : verified_runtime option;
}

let expected_verification_schema = "masc.runtime_verification.v1"

let encode_account_verify ~provider_account_id ~model =
  `Assoc
    [
      ("provider_account_id", `String (String.trim provider_account_id));
      ("model", `String (String.trim model));
    ]

let decode_account_verify_response json =
  let* obj = require_object ~context:setup_accounts_verify_path json in
  let* vobj = required_object_field obj "verification" in
  let* schema = required_nonblank_string vobj "schema" in
  let* () =
    if String.equal schema expected_verification_schema then Ok ()
    else
      Error
        (Printf.sprintf "unexpected verification schema %S (expected %S)" schema
           expected_verification_schema)
  in
  let* runtime_id = required_nonblank_string vobj "runtime_id" in
  let* model = required_nullable_nonblank_string vobj "model" in
  let* observed_model =
    required_nullable_nonblank_string vobj "observed_model"
  in
  let* status_raw = required_nonblank_string vobj "status" in
  let* status = verification_status_of_string status_raw in
  let* checks_obj = required_object_field vobj "checks" in
  let* response = required_bool_field checks_obj "response" in
  let* tool_called = required_bool_field checks_obj "tool_called" in
  let* tool_roundtrip = required_bool_field checks_obj "tool_roundtrip" in
  let* failure_obj = required_nullable_object_field vobj "failure" in
  let* failure =
    match failure_obj with
    | None -> Ok None
    | Some fobj ->
        let* code = required_nonblank_string fobj "code" in
        let* message = required_nonblank_string fobj "message" in
        let* detail = required_nullable_nonblank_string fobj "detail" in
        Ok (Some { code; message; detail })
  in
  let* runtime_obj = required_nullable_object_field obj "runtime" in
  let* runtime =
    match runtime_obj with
    | None -> Ok None
    | Some robj ->
        let* rt_id = required_nonblank_string robj "runtime_id" in
        let* rec_raw = required_nonblank_string robj "record" in
        let* record = runtime_record_outcome_of_string rec_raw in
        Ok (Some { runtime_id = rt_id; record })
  in
  Ok
    {
      verification =
        {
          schema;
          runtime_id;
          model;
          observed_model;
          status;
          checks = { response; tool_called; tool_roundtrip };
          failure;
        };
      runtime;
    }

(* ---- Key Account Registration, Replacement & Removal ---- *)

type key_register_response = {
  provider_account_id : string;
  kind : string;
}

type key_replace_response = {
  provider_account_id : string;
  old_keys_removed : bool;
}

type key_remove_response = {
  provider_account_id : string;
  removed : bool;
}

let encode_key_register ~integration_id ~key =
  `Assoc
    [
      ("integration_id", `String (String.trim integration_id));
      ("key", `String key);
    ]

let encode_key_replace ~key = `Assoc [ ("key", `String key) ]
let encode_login_cancel () = `Assoc []

let decode_key_register_response json =
  let* obj = require_object ~context:setup_accounts_key_path json in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* kind = required_nonblank_string obj "kind" in
  let* () =
    if String.equal kind "key" then Ok ()
    else
      Error
        (Printf.sprintf "unexpected key register kind %S (expected \"key\")"
           kind)
  in
  Ok { provider_account_id; kind }

let decode_key_replace_response json =
  let* obj = require_object ~context:"PUT /api/v1/setup/accounts/key/:id" json in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* old_keys_removed = required_bool_field obj "old_keys_removed" in
  Ok { provider_account_id; old_keys_removed }

let decode_key_remove_response json =
  let* obj =
    require_object ~context:"DELETE /api/v1/setup/accounts/key/:id" json
  in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* removed = required_bool_field obj "removed" in
  let* () =
    if removed then Ok ()
    else Error "DELETE /api/v1/setup/accounts/key/:id returned removed=false"
  in
  Ok { provider_account_id; removed }
