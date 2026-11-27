(** Strict fail-closed wire codecs for Multi-Account own-provider inspection
    and management endpoints:
    - [GET /api/v1/auth/provider-accounts]
    - [GET /api/v1/auth/integrations]
    - [POST /api/v1/setup/accounts/verify]
    - [POST /api/v1/setup/accounts/key]
    - [PUT /api/v1/setup/accounts/key/:provider_account_id]
    - [DELETE /api/v1/setup/accounts/key/:provider_account_id]
    - [POST /api/v1/setup/accounts/login/:login_id/cancel]

    Every decoder rejects non-object roots, non-array lists, non-object rows,
    missing required fields, contradictory field combinations, and unknown enum
    values without silent defaults or lossy filtering. *)

val auth_provider_accounts_path : string
val auth_integrations_path : string
val setup_accounts_verify_path : string
val setup_accounts_key_path : string
val setup_accounts_key_entry_path : provider_account_id:string -> string
val setup_accounts_login_cancel_path : login_id:string -> string

(** {1 Provider Accounts & Runtimes ([GET /api/v1/auth/provider-accounts])} *)

type provider_key_state =
  | Key_readable
  | Key_missing
  | Key_unreadable
  | Key_not_looked_at

val equal_provider_key_state : provider_key_state -> provider_key_state -> bool
val provider_key_state_to_string : provider_key_state -> string

type provider_account_kind =
  | Provider_login
  | Provider_key of provider_key_state

val equal_provider_account_kind :
  provider_account_kind -> provider_account_kind -> bool

type provider_removal_state =
  | Removal_start_given_up
  | Removal_key_not_removed
  | Removal_home_not_removed

val equal_provider_removal_state :
  provider_removal_state -> provider_removal_state -> bool
val provider_removal_state_to_string : provider_removal_state -> string

type provider_replacement_state =
  | Replacement_start_given_up

val equal_provider_replacement_state :
  provider_replacement_state -> provider_replacement_state -> bool
val provider_replacement_state_to_string : provider_replacement_state -> string

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

val equal_runtime_unread_reason :
  runtime_unread_reason -> runtime_unread_reason -> bool
val runtime_unread_reason_to_string : runtime_unread_reason -> string

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

val decode_provider_accounts_snapshot :
  Yojson.Safe.t -> (provider_accounts_snapshot, string) result

(** {1 Person Integrations ([GET /api/v1/auth/integrations])} *)

type connect_method =
  | Connect_login
  | Connect_key

val equal_connect_method : connect_method -> connect_method -> bool
val connect_method_to_string : connect_method -> string

type withheld_model = {
  model : string;
  reason : string;
}

type integration_refusal =
  | Refusal_native_unpublished
  | Refusal_native_tools_reach_other_homes
  | Refusal_native_tools_reach_person_homes
  | Refusal_person_homes_unread

val equal_integration_refusal :
  integration_refusal -> integration_refusal -> bool
val integration_refusal_to_string : integration_refusal -> string

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

val decode_person_integrations_snapshot :
  Yojson.Safe.t -> (person_integrations_snapshot, string) result

(** {1 Provider Account Verification ([POST /api/v1/setup/accounts/verify])} *)

type verification_status =
  | Verify_verified
  | Verify_failed
  | Verify_unavailable

val equal_verification_status :
  verification_status -> verification_status -> bool
val verification_status_to_string : verification_status -> string

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

val equal_runtime_record_outcome :
  runtime_record_outcome -> runtime_record_outcome -> bool
val runtime_record_outcome_to_string : runtime_record_outcome -> string

type verified_runtime = {
  runtime_id : string;
  record : runtime_record_outcome;
}

type account_verify_response = {
  verification : verification_result;
  runtime : verified_runtime option;
}

val encode_account_verify :
  provider_account_id:string -> model:string -> Yojson.Safe.t
val decode_account_verify_response :
  Yojson.Safe.t -> (account_verify_response, string) result

(** {1 Key Account Registration, Rotation & Removal ([/api/v1/setup/accounts/key*])} *)

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

val encode_key_register : integration_id:string -> key:string -> Yojson.Safe.t
val encode_key_replace : key:string -> Yojson.Safe.t
val encode_login_cancel : unit -> Yojson.Safe.t

val decode_key_register_response :
  Yojson.Safe.t -> (key_register_response, string) result
val decode_key_replace_response :
  Yojson.Safe.t -> (key_replace_response, string) result
val decode_key_remove_response :
  Yojson.Safe.t -> (key_remove_response, string) result
