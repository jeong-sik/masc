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
  | Made_off

let made_by : Authz_mode_event.event -> log_mode = function
  | Fresh_bootstrap | Reactivate -> Made_multi_account
  | Off -> Made_off
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
  | Activation_requested
  | Multi_account
  | Multi_account_uncertain

type refusal =
  | Unknown_account_mode of string
  | Authorization_log_unreadable of string
  | Rewound_before_bootstrap
  | Downgraded_from_multi_account
  | Off_mode_not_supported
  | Reactivation_not_ready
  | Rewound_after_off
  | Auth_disabled_in_multi_account
  | Token_not_required_in_multi_account
  | Anonymous_mutations_in_multi_account
  | Auth_settings_unreadable_in_multi_account of string

(* The three values of the high-water column of the table in design 5.1. *)
type high_water_column =
  | Absent
  | Matches
  | Present_not_matching

let column = function
  | Judged Authz_high_water.Absent -> Absent
  | Judged Authz_high_water.Matches -> Matches
  | Judged (Authz_high_water.Mismatch _) | Store_unreadable _ -> Present_not_matching
;;

(* The config column of the table: no member and [Single_user] are one row. *)
type config_column =
  | Asks_single_user
  | Asks_multi_account
  | Asks_unknown of string

let config_column = function
  | Not_set | Requested Masc_domain.Single_user -> Asks_single_user
  | Requested Masc_domain.Multi_account -> Asks_multi_account
  | Unknown_value text -> Asks_unknown text
;;

(* The log as the rows read it, once the cases that the log decides alone are
   taken out: a log that cannot be read, and [Off] with a store that does not
   match it, are refused whatever the config asks (design 5.1, the paragraph
   after the table, and row 10). *)
type readable_log =
  | No_event
  | Made_multi
  | Off_matched

let readable_log log high_water : (readable_log, refusal) result =
  match log, high_water with
  | Log_unreadable detail, (Absent | Matches | Present_not_matching) ->
    Error (Authorization_log_unreadable detail)
  | Made_off, (Absent | Present_not_matching) -> Error Rewound_after_off
  | Made_off, Matches -> Ok Off_matched
  | No_mode_event, (Absent | Matches | Present_not_matching) -> Ok No_event
  | Made_multi_account, (Absent | Matches | Present_not_matching) -> Ok Made_multi
;;

(* Rows 1 to 4 of the table. *)
let single_user_row log high_water : (mode, refusal * refusal list) result =
  match log, high_water with
  | No_event, Absent -> Ok Single_user
  | No_event, (Matches | Present_not_matching) -> Error (Rewound_before_bootstrap, [])
  | Made_multi, (Absent | Matches | Present_not_matching) ->
    Error (Downgraded_from_multi_account, [])
  | Off_matched, (Absent | Matches | Present_not_matching) -> Error (Off_mode_not_supported, [])
;;

(* Rows 5 to 9 of the table. *)
let multi_account_row log high_water : (mode, refusal * refusal list) result =
  match log, high_water with
  | No_event, Absent -> Ok Activation_requested
  | No_event, (Matches | Present_not_matching) -> Error (Rewound_before_bootstrap, [])
  | Made_multi, Matches -> Ok Multi_account
  | Made_multi, (Absent | Present_not_matching) -> Ok Multi_account_uncertain
  | Off_matched, (Absent | Matches | Present_not_matching) -> Error (Reactivation_not_ready, [])
;;

let settings_reasons config input =
  match config with
  | Asks_single_user | Asks_unknown _ -> []
  | Asks_multi_account ->
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
  let config = config_column input.requested in
  let high_water = column input.high_water in
  let by_table =
    match config, readable_log input.log_mode high_water with
    | Asks_unknown text, Ok (No_event | Made_multi | Off_matched) ->
      Error (Unknown_account_mode text, [])
    | Asks_unknown text, Error by_log -> Error (Unknown_account_mode text, [ by_log ])
    | (Asks_single_user | Asks_multi_account), Error by_log -> Error (by_log, [])
    | Asks_single_user, Ok log -> single_user_row log high_water
    | Asks_multi_account, Ok log -> multi_account_row log high_water
  in
  match by_table, settings_reasons config input with
  | Ok mode, [] -> Ok mode
  | Ok _, first :: rest -> Error (first, rest)
  | Error (first, rest), settings -> Error (first, rest @ settings)
;;

let mode_to_string = function
  | Single_user -> "single_user"
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
     account_mode to \"Multi_account\""
  | Off_mode_not_supported ->
    "the last mode event of the authorization log is Off, which this server cannot boot yet"
  | Reactivation_not_ready ->
    "config.json asks for Multi_account after an Off mode event; reactivation needs the \
     recovery procedure, which this server does not have yet"
  | Rewound_after_off ->
    "the last mode event is Off and the external store does not match the authorization log"
  | Auth_disabled_in_multi_account -> "Multi_account needs auth enabled (config.json enabled=true)"
  | Token_not_required_in_multi_account ->
    "Multi_account needs require_token=true in config.json"
  | Anonymous_mutations_in_multi_account ->
    "Multi_account refuses MASC_ALLOW_ANONYMOUS_MUTATIONS=true"
  | Auth_settings_unreadable_in_multi_account detail ->
    "Multi_account needs a config.json that decodes: " ^ detail
;;
