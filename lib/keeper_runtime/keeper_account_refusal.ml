type key_unusable_reason =
  | Key_missing
  | Path_not_absolute
  | Not_a_regular_file
  | Open_to_others
  | Not_a_key

type t =
  | Access_not_published
  | Operator_turn_refused
  | Authorization_zone_uncertain
  | Channel_not_allowed
  | Caller_not_authorized
  | Pat_expired
  | Pat_scope_not_explicit
  | Scope_or_grant_refused
  | Owner_inactive
  | Provider_account_unavailable
  | Runtime_reassigned
  | Unknown_keeper
  | Authorization_not_bootstrapped
  | Account_home_unresolved
  | Account_home_invalid
  | Key_unusable of key_unusable_reason
  | Host_account_refused
  | Accounts_disabled

type Agent_core.Error.carrier += Account_refused of t

let all =
  [ Access_not_published
  ; Operator_turn_refused
  ; Authorization_zone_uncertain
  ; Channel_not_allowed
  ; Caller_not_authorized
  ; Pat_expired
  ; Pat_scope_not_explicit
  ; Scope_or_grant_refused
  ; Owner_inactive
  ; Provider_account_unavailable
  ; Runtime_reassigned
  ; Unknown_keeper
  ; Authorization_not_bootstrapped
  ; Account_home_unresolved
  ; Account_home_invalid
  ; Key_unusable Key_missing
  ; Key_unusable Path_not_absolute
  ; Key_unusable Not_a_regular_file
  ; Key_unusable Open_to_others
  ; Key_unusable Not_a_key
  ; Host_account_refused
  ; Accounts_disabled
  ]
;;

let equal left right = left = right

let key_unusable_reason_to_wire = function
  | Key_missing -> "key_missing"
  | Path_not_absolute -> "path_not_absolute"
  | Not_a_regular_file -> "not_a_regular_file"
  | Open_to_others -> "open_to_others"
  | Not_a_key -> "not_a_key"
;;

let to_wire = function
  | Access_not_published -> "access_not_published"
  | Operator_turn_refused -> "operator_turn_refused"
  | Authorization_zone_uncertain -> "authorization_zone_uncertain"
  | Channel_not_allowed -> "channel_not_allowed"
  | Caller_not_authorized -> "caller_not_authorized"
  | Pat_expired -> "pat_expired"
  | Pat_scope_not_explicit -> "pat_scope_not_explicit"
  | Scope_or_grant_refused -> "scope_or_grant_refused"
  | Owner_inactive -> "owner_inactive"
  | Provider_account_unavailable -> "provider_account_unavailable"
  | Runtime_reassigned -> "runtime_reassigned"
  | Unknown_keeper -> "unknown_keeper"
  | Authorization_not_bootstrapped -> "authorization_not_bootstrapped"
  | Account_home_unresolved -> "account_home_unresolved"
  | Account_home_invalid -> "account_home_invalid"
  | Key_unusable reason -> "key_unusable:" ^ key_unusable_reason_to_wire reason
  | Host_account_refused -> "host_account_refused"
  | Accounts_disabled -> "accounts_disabled"
;;

let of_wire raw =
  match List.find_opt (fun item -> String.equal (to_wire item) raw) all with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "unknown account refusal %S" raw)
;;

let key_unusable_reason_to_string = function
  | Key_missing -> "the API key file is missing"
  | Path_not_absolute -> "the API key file must use an absolute path"
  | Not_a_regular_file ->
    "the API key file could not be read as an owned regular file"
  | Open_to_others ->
    "the API key file must be owned by the current user and private"
  | Not_a_key -> "the API key file does not hold one raw API key"
;;

let to_string = function
  | Access_not_published ->
    "The runtime account access configuration has not been published."
  | Operator_turn_refused ->
    "Multi-account mode does not run operator calls or operator Keepers."
  | Authorization_zone_uncertain ->
    "The authorization zone is unavailable or inconsistent; the turn was refused."
  | Channel_not_allowed ->
    "This Keeper is not authorized to run on this turn channel."
  | Caller_not_authorized ->
    "The caller is not authorized to run a turn for this Keeper."
  | Pat_expired -> "The authorization token used for this request has expired."
  | Pat_scope_not_explicit ->
    "The authorization token does not carry an explicit scope."
  | Scope_or_grant_refused ->
    "The Keeper's authorization scope or runtime grant no longer permits this turn."
  | Owner_inactive -> "The owner of this Keeper is no longer active."
  | Provider_account_unavailable ->
    "The provider account for this Keeper is unavailable or being removed."
  | Runtime_reassigned ->
    "The Keeper was assigned another Runtime before this attempt ran."
  | Unknown_keeper -> "This Keeper is no longer registered in the authorization log."
  | Authorization_not_bootstrapped ->
    "The authorization log has not been bootstrapped."
  | Account_home_unresolved ->
    "The home directory of the provider account could not be resolved."
  | Account_home_invalid ->
    "The provider account home configuration did not match the authorized account."
  | Key_unusable reason -> key_unusable_reason_to_string reason
  | Host_account_refused ->
    "Multi-account mode does not share host provider accounts."
  | Accounts_disabled ->
    "Person accounts have been disabled in this workspace."
;;

let core_error refusal =
  Agent_core.Error.Internal_carried
    { message = to_string refusal; carrier = Account_refused refusal }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried { carrier = Account_refused refusal; _ } ->
    Some refusal
  | ( Agent_core.Error.Api _
    | Provider _
    | Agent _
    | Mcp _
    | Config _
    | Serialization _
    | Io _
    | Orchestration _ | Media _
    | Internal _
    | Internal_carried _ ) -> None
;;
