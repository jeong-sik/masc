(* HIGH-RISK-UNREVIEWED: this module decides the account mode a server boots in.
   A wrong answer boots a rolled-back multi-account installation as a single
   user, or boots one with auth turned off. *)

type requested =
  | Not_set
  | Requested of Masc_domain.account_mode
  | Unknown_value of string

type log_mode =
  | Log_unreadable of string
  | No_mode_event
  | Made_multi_account
  | Made_off of Authz_state.t

let of_state (state : Authz_state.t) =
  match state.Authz_state.mode with
  | Authz_mode_state.Not_bootstrapped -> No_mode_event
  | Authz_mode_state.Multi_account _ -> Made_multi_account
  | Authz_mode_state.Off _ -> Made_off state
;;

type high_water =
  | Store_unreadable of string
  | Judged of Authz_high_water.t

type settings =
  | Settings_read of
      { enabled : bool
      ; require_token : bool
      }
  | Settings_unreadable of string

type input =
  { requested : requested
  ; log_mode : log_mode
  ; high_water : high_water
  ; settings : settings
  ; anonymous_mutations : bool
  }

type mode =
  | Single_user
  | Single_user_after_off of Authz_state.t
  | Activation_requested
  | Multi_account
  | Multi_account_uncertain

type refusal =
  | Unknown_account_mode of string
  | Authorization_log_unreadable of string
  | Rewound_before_bootstrap
  | Downgraded_from_multi_account
  | Reactivation_not_ready
  | Rewound_after_off
  | External_store_unreadable of string
  | Auth_disabled_in_multi_account
  | Token_not_required_in_multi_account
  | Anonymous_mutations_in_multi_account
  | Auth_settings_unreadable_in_multi_account of string

(* The high-water column of the table in design 5.1. The table puts a store
   that cannot be read in one cell with a mismatch; it is kept apart here so
   that a refusal says which of the two it was. *)
type high_water_column =
  | Absent
  | Matches
  | Mismatch_found
  | Unreadable of string

let column = function
  | Judged Authz_high_water.Absent -> Absent
  | Judged Authz_high_water.Matches -> Matches
  | Judged (Authz_high_water.Mismatch _) -> Mismatch_found
  | Store_unreadable detail -> Unreadable detail
;;

(* The config column of the table: no member and [Single_user] are one row. *)
type asked =
  | Asks_single_user
  | Asks_multi_account

(* HIGH-RISK-UNREVIEWED: the one reading of the request. The boot judgment and
   every command that holds no lease take the account mode from here, so a
   value the table does not know is a refusal to each of them and never a
   single user. *)
let asked = function
  | Not_set | Requested Masc_domain.Single_user -> Ok Asks_single_user
  | Requested Masc_domain.Multi_account -> Ok Asks_multi_account
  | Unknown_value text -> Error (Unknown_account_mode text)
;;

(* The log as the rows read it, once the cases that the log and the store decide
   whatever the config asks are taken out (design 5.1): a log that cannot be
   read (the paragraph after the table), no mode event over a store that has
   one (rows 2 and 6), and [Off] over a store that does not match it (row 10).
   [No_event] is left only with an absent store, and [Off_matched] only with a
   matching one. *)
type readable_log =
  | No_event
  | Made_multi of high_water_column
  | Off_matched of Authz_state.t

let readable_log log high_water : (readable_log, refusal) result =
  match log, high_water with
  | Log_unreadable detail, (Absent | Matches | Mismatch_found | Unreadable _) ->
    Error (Authorization_log_unreadable detail)
  | No_mode_event, Absent -> Ok No_event
  | No_mode_event, (Matches | Mismatch_found) -> Error Rewound_before_bootstrap
  | No_mode_event, Unreadable detail -> Error (External_store_unreadable detail)
  | Made_off state, Matches -> Ok (Off_matched state)
  | Made_off (_ : Authz_state.t), (Absent | Mismatch_found) -> Error Rewound_after_off
  | Made_off (_ : Authz_state.t), Unreadable detail -> Error (External_store_unreadable detail)
  | Made_multi_account, high_water -> Ok (Made_multi high_water)
;;

(* Rows 1, 3 and 4 of the table. *)
let single_user_row : readable_log -> (mode, refusal * refusal list) result = function
  | No_event -> Ok Single_user
  | Made_multi _ -> Error (Downgraded_from_multi_account, [])
  | Off_matched state -> Ok (Single_user_after_off state)
;;

(* Rows 5, 7, 8 and 9 of the table. *)
let multi_account_row : readable_log -> (mode, refusal * refusal list) result = function
  | No_event -> Ok Activation_requested
  | Made_multi Matches -> Ok Multi_account
  | Made_multi (Absent | Mismatch_found | Unreadable _) -> Ok Multi_account_uncertain
  | Off_matched (_ : Authz_state.t) -> Error (Reactivation_not_ready, [])
;;

let settings_reasons config input =
  match config with
  | Ok Asks_single_user | Error (_ : refusal) -> []
  | Ok Asks_multi_account ->
    let settings =
      match input.settings with
      | Settings_unreadable detail -> [ Auth_settings_unreadable_in_multi_account detail ]
      | Settings_read { enabled; require_token } ->
        (if enabled then [] else [ Auth_disabled_in_multi_account ])
        @ if require_token then [] else [ Token_not_required_in_multi_account ]
    in
    settings
    @ if input.anonymous_mutations then [ Anonymous_mutations_in_multi_account ] else []
;;

let judge input =
  let config = asked input.requested in
  let high_water = column input.high_water in
  let by_table =
    match config, readable_log input.log_mode high_water with
    | Error unknown, Ok (No_event | Made_multi _ | Off_matched _) -> Error (unknown, [])
    | Error unknown, Error by_log -> Error (unknown, [ by_log ])
    | Ok (Asks_single_user | Asks_multi_account), Error by_log -> Error (by_log, [])
    | Ok Asks_single_user, Ok log -> single_user_row log
    | Ok Asks_multi_account, Ok log -> multi_account_row log
  in
  match by_table, settings_reasons config input with
  | Ok mode, [] -> Ok mode
  | Ok _, first :: rest -> Error (first, rest)
  | Error (first, rest), settings -> Error (first, rest @ settings)
;;

let mode_to_string = function
  | Single_user -> "single_user"
  | Single_user_after_off (_ : Authz_state.t) -> "single_user_after_off"
  | Activation_requested -> "activation_requested"
  | Multi_account -> "multi_account"
  | Multi_account_uncertain -> "multi_account_uncertain"
;;

let refusal_to_string = function
  | Unknown_account_mode text ->
    Printf.sprintf
      "config.json account_mode is %s; it must be the string \"Single_user\" or \"Multi_account\""
      text
  | Authorization_log_unreadable detail ->
    "the authorization log cannot be read: " ^ detail
  | Rewound_before_bootstrap ->
    "the external store records a multi-account installation that the authorization log does not \
     hold; the base path was restored to before its bootstrap"
  | Downgraded_from_multi_account ->
    "the authorization log made Multi_account and config.json does not ask for it; set \
     account_mode to \"Multi_account\", or turn the accounts off with masc auth off while no \
     server runs"
  | Reactivation_not_ready ->
    "config.json asks for Multi_account after an Off mode event; reactivation needs the \
     recovery procedure, which this build does not have yet"
  | Rewound_after_off ->
    "the last mode event is Off and the external store does not match the authorization log"
  | External_store_unreadable detail ->
    "the install record or the external store cannot be read, so the boot cannot tell whether \
     the base path was restored to before its bootstrap: " ^ detail
  | Auth_disabled_in_multi_account -> "Multi_account needs auth enabled (config.json enabled=true)"
  | Token_not_required_in_multi_account ->
    "Multi_account needs require_token=true in config.json"
  | Anonymous_mutations_in_multi_account ->
    "Multi_account refuses MASC_ALLOW_ANONYMOUS_MUTATIONS=true"
  | Auth_settings_unreadable_in_multi_account detail ->
    "Multi_account needs a config.json that decodes: " ^ detail
;;
