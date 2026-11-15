(* HIGH-RISK-UNREVIEWED: this module reads what the boot judgment of the account
   mode decides on. Reading a file that is there as absent boots a rolled-back
   multi-account installation as a single user. *)

module B = Authz_boot_mode
module H = Authz_high_water
module I = Authz_install_record
module L = Authz_log
module P = Authz_presence
module R = Authz_record
module S = Authz_external_store

let member_name = "account_mode"

let requested_of_json : Yojson.Safe.t -> B.requested = function
  | `Assoc fields ->
    let values =
      List.filter_map
        (fun (name, value) -> if String.equal name member_name then Some value else None)
        fields
    in
    (match values with
     | [] -> B.Not_set
     | [ value ] ->
       (match Masc_domain.account_mode_of_json value with
        | Some mode -> B.Requested mode
        | None -> B.Unknown_value (Yojson.Safe.to_string value))
     | _ :: _ :: _ ->
       B.Unknown_value (String.concat ", " (List.map Yojson.Safe.to_string values)))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> B.Not_set
;;

let settings_of (config : Masc_domain.auth_config) =
  B.Settings_read { enabled = config.enabled; require_token = config.require_token }
;;

type login_clients =
  { google : Masc_domain.login_client option
  ; github : Masc_domain.login_client option
  }

let no_login_clients = { google = None; github = None }

let login_clients_of (config : Masc_domain.auth_config) =
  { google = config.google; github = config.github }
;;

(* The file is read once, and the member and the other fields come from the
   same bytes. *)
let read_config_and_clients ~base_path =
  let file = Auth_credential_base.auth_config_file base_path in
  let absent detail =
    Log.Auth.warn "%s is read as absent for the account mode: %s" file detail;
    B.Not_set, B.Settings_unreadable detail, no_login_clients
  in
  match P.of_path file with
  | P.Cannot_check detail -> absent detail
  | P.Not_there ->
    B.Not_set, settings_of Masc_domain.default_auth_config, no_login_clients
  | P.There ->
    (match Auth_credential_base.read_regular_auth_file file with
     | Error error -> absent (Masc_domain.masc_error_to_string error)
     | Ok content ->
       (match Yojson.Safe.from_string content with
        | exception Yojson.Json_error detail -> absent ("not JSON: " ^ detail)
        | `Assoc _ as json ->
          let settings, login_clients =
            match Masc_domain.auth_config_of_yojson json with
            | Ok config -> settings_of config, login_clients_of config
            | Error detail -> B.Settings_unreadable detail, no_login_clients
          in
          requested_of_json json, settings, login_clients
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json ->
          absent ("not a JSON object: " ^ Yojson.Safe.to_string json)))
;;

let read_config ~base_path =
  let requested, settings, (_ : login_clients) = read_config_and_clients ~base_path in
  requested, settings
;;

(* HIGH-RISK-UNREVIEWED: what a command that holds no lease takes for the
   account mode. It is the reading of the boot judgment ([B.asked]) and holds
   no rule of its own. *)
let asked ~base_path =
  let requested, (_ : B.settings) = read_config ~base_path in
  B.asked requested
;;

(* The external store that the install record names, as the boot found it. *)
type store_read =
  | Store_unreadable of string
  | No_store
      (* No config directory, no record, or no store where the record points
         (design 8.4). *)
  | Store_read of
      { path : I.Store_path.t
      ; state : S.State.t
      }

let read_store ~config_dir ~base_path =
  match I.locate ~config_dir ~base_path with
  | Error error -> Store_unreadable (I.locate_error_to_string error)
  | Ok located ->
    (match I.read located with
     | Error error -> Store_unreadable (I.read_error_to_string error)
     | Ok None -> No_store
     | Ok (Some store) ->
       let path = (store : I.Store_path.t :> string) in
       (match P.of_path path with
        | P.Not_there -> No_store
        | P.Cannot_check detail ->
          Store_unreadable (Printf.sprintf "the external store %s: %s" path detail)
        | P.There ->
          (match S.open_at_start ~path ~init:S.State.empty ~step:S.apply with
           | Error error -> Store_unreadable (S.open_error_to_string S.violation_to_string error)
           | Ok (_store, _state, { S.contents = S.Missing; _ }) -> No_store
           | Ok (_store, state, { S.contents = S.Empty | S.Lines _; _ }) ->
             Store_read { path = store; state })))
;;

(* The log as the boot found it. Whether the log or the store is there is read
   before the lock of its file is taken, so this needs every process that
   creates either file to hold the BasePath lease, as the boot does. *)
type log_read =
  | Log_not_there
  | Log_cannot_check of string
  | Log_opened of (Authz_zone.Replay.t, string) result

let read_log ~base_path ~state =
  let path = L.path_of_base_path ~base_path in
  match P.of_path path with
  | P.Not_there -> Log_not_there
  | P.Cannot_check detail -> Log_cannot_check (Printf.sprintf "%s: %s" path detail)
  | P.There ->
    (match
       L.open_at_start ~path ~init:(Authz_zone.Replay.init state) ~step:Authz_zone.Replay.step
     with
     | Error error -> Log_opened (Error (L.open_error_to_string Authz_state.refusal_to_string error))
     | Ok (_log, replay, _recovered) -> Log_opened (Ok replay))
;;

(* The log and the store of one boot, read once: the store first, because the
   replay of the log starts from its state. *)
type files =
  { store : store_read
  ; log_mode : B.log_mode
  ; high_water : B.high_water
  }

let read_files ~base_path ~config_dir =
  let store = read_store ~config_dir ~base_path in
  let state =
    match store with
    | Store_read { path = _; state } -> state
    | No_store | Store_unreadable _ -> S.State.empty
  in
  let log = read_log ~base_path ~state in
  let log_mode =
    match log with
    | Log_not_there -> B.No_mode_event
    | Log_cannot_check detail | Log_opened (Error detail) -> B.Log_unreadable detail
    | Log_opened (Ok replay) -> B.of_state replay.Authz_zone.Replay.state
  in
  let high_water =
    match store, log with
    | Store_unreadable detail, (Log_not_there | Log_cannot_check _ | Log_opened _) ->
      B.Store_unreadable detail
    | No_store, (Log_not_there | Log_cannot_check _ | Log_opened _) -> B.Judged H.Absent
    | Store_read _, Log_opened (Ok replay) -> B.Judged (H.judge replay.Authz_zone.Replay.probe)
    | Store_read { path = _; state }, Log_not_there -> B.Judged (H.judge (H.Probe.create state))
    | Store_read _, (Log_cannot_check _ | Log_opened (Error _)) ->
      B.Store_unreadable "it was not judged, because the authorization log cannot be read"
  in
  { store; log_mode; high_water }
;;

let read_log_and_store ~base_path ~config_dir =
  let { store = _; log_mode; high_water } = read_files ~base_path ~config_dir in
  log_mode, high_water
;;

(* The config is read once: the input of the judgment and the login clients
   come from the same bytes. *)
let input_and_clients_of_files
      ~base_path
      ~anonymous_mutations
      { store = _; log_mode; high_water }
  =
  let requested, settings, login_clients = read_config_and_clients ~base_path in
  { B.requested; log_mode; high_water; settings; anonymous_mutations }, login_clients
;;

let input ~base_path ~config_dir ~anonymous_mutations =
  let input, (_ : login_clients) =
    input_and_clients_of_files
      ~base_path
      ~anonymous_mutations
      (read_files ~base_path ~config_dir)
  in
  input
;;

type stop =
  | Refuse of B.refusal * B.refusal list
  | Activation_requested
  | Authorization_uncertain

type decision =
  | Boot_single_user
  | Boot_after_off of Authz_state.t
  | Boot_multi_account
  | Stop of stop

let decide input =
  match B.judge input with
  | Ok B.Single_user -> Boot_single_user
  | Ok (B.Single_user_after_off state) -> Boot_after_off state
  | Ok B.Activation_requested -> Stop Activation_requested
  | Ok B.Multi_account -> Boot_multi_account
  | Ok B.Multi_account_uncertain -> Stop Authorization_uncertain
  | Error (first, rest) -> Stop (Refuse (first, rest))
;;

let high_water_detail = function
  | B.Store_unreadable detail -> [ "the external store cannot be read: " ^ detail ]
  | B.Judged (H.Mismatch (first, rest)) ->
    List.map
      (fun reason ->
        "the external store does not match the authorization log: " ^ H.reason_to_string reason)
      (first :: rest)
  | B.Judged H.Absent ->
    [ "no external store answers for this base path: no install record of the masc config \
       directory names it, or the store that the record names is not there or holds no answer"
    ]
  | B.Judged H.Matches -> []
;;

let turn_off_line =
  "to boot a single user that keeps the records of the accounts read-only, stop every masc \
   process on the workspace, run masc auth off, and take account_mode out of config.json"
;;

let account_installation_line ~base_path =
  Printf.sprintf
    "%s asks for Multi_account, so a boot of this workspace runs the account server or \
     stops, and never runs the server of a single user: masc auth bootstrap activates the \
     workspace while no server runs, and masc restart starts or replaces the account server"
    (Auth_credential_base.auth_config_file base_path)
;;

let refused_line ~base_path refusal =
  Printf.sprintf
    "%s. No boot runs a server on this workspace until %s is corrected"
    (B.refusal_to_string refusal)
    (Auth_credential_base.auth_config_file base_path)
;;

let messages (input : B.input) = function
  | Refuse (first, rest) -> B.refusal_to_string first, List.map B.refusal_to_string rest
  | Activation_requested ->
    ( "config.json asks for Multi_account and nothing is set up yet (Activation_requested)"
    , [ "masc auth bootstrap --external-store PATH, run while no server runs, activates the \
         workspace; a server then boots it as a multi-account installation"
      ; "without account_mode in config.json, a boot starts a single user"
      ] )
  | Authorization_uncertain ->
    ( "the authorization log made Multi_account and the external store does not confirm it \
       (AuthorizationUncertain); no server serves the workspace until the two agree, and this \
       build has no recovery procedure that makes them agree"
    , high_water_detail input.high_water )
;;

type single_user =
  | Never_set_up of string
  | Turned_off of
      { base_path : string
      ; state : Authz_state.t
      }

let single_user_base_path = function
  | Never_set_up base_path | Turned_off { base_path; state = _ } -> base_path
;;

let turned_off = function
  | Never_set_up (_ : string) -> None
  | Turned_off { base_path = _; state } -> Some state
;;

type multi_account =
  { base_path : string
  ; external_store : I.Store_path.t
  ; login_clients : login_clients
  }

let multi_account_base_path { base_path; external_store = _; login_clients = _ } = base_path

let multi_account_external_store { base_path = _; external_store; login_clients = _ } =
  (external_store : I.Store_path.t :> string)
;;

let multi_account_login_clients { base_path = _; external_store = _; login_clients } =
  login_clients
;;

type booted =
  | Single_user of single_user
  | Multi_account of multi_account

let boot ~base_path ~config_dir ~anonymous_mutations =
  let files = read_files ~base_path ~config_dir in
  let input, login_clients =
    input_and_clients_of_files ~base_path ~anonymous_mutations files
  in
  match decide input, files.store with
  | Boot_single_user, (Store_unreadable _ | No_store | Store_read _) ->
    Ok (Single_user (Never_set_up base_path))
  | Boot_after_off state, (Store_unreadable _ | No_store | Store_read _) ->
    Ok (Single_user (Turned_off { base_path; state }))
  | Boot_multi_account, Store_read { path; state = _ } ->
    Ok (Multi_account { base_path; external_store = path; login_clients })
  | Boot_multi_account, (Store_unreadable _ | No_store) ->
    (* The table gives Multi_account only for a store that matches the log
       ([B.Judged H.Matches]), which [read_files] makes only from a store it
       read. A boot that got here has no store to open a zone over. *)
    Error
      ( "the account mode was judged Multi_account, and the boot read no external store to \
         serve it over"
      , [] )
  | Stop stop, (Store_unreadable _ | No_store | Store_read _) -> Error (messages input stop)
;;

let tool_refused =
  "a host tool runs turns only on a base path that was never set up for accounts, and does \
   not open the authorization files a server may be writing"
;;

(* What says the base path was set up for accounts, as presence only: the log,
   and the install record that names the external store. *)
let traces ~base_path ~config_dir =
  let log_path = L.path_of_base_path ~base_path in
  let log =
    match P.of_path log_path with
    | P.Not_there -> []
    | P.There -> [ "the authorization log " ^ log_path ^ " is there" ]
    | P.Cannot_check detail -> [ "the authorization log " ^ log_path ^ ": " ^ detail ]
  in
  let record =
    match I.locate ~config_dir ~base_path with
    | Error error -> [ I.locate_error_to_string error ]
    | Ok located ->
      (match I.read located with
       | Ok None -> []
       | Ok (Some store) ->
         [ "an install record names this base path and the external store "
           ^ (store : I.Store_path.t :> string)
         ]
       | Error error -> [ I.read_error_to_string error ])
  in
  log @ record
;;

let tool ~base_path ~config_dir =
  match traces ~base_path ~config_dir with
  | _ :: _ as found -> Error (tool_refused, found)
  | [] ->
    let requested, settings = read_config ~base_path in
    (* A tool serves no HTTP, so it has no anonymous mutations. *)
    let input =
      { B.requested
      ; log_mode = B.No_mode_event
      ; high_water = B.Judged H.Absent
      ; settings
      ; anonymous_mutations = false
      }
    in
    (match decide input with
     | Boot_single_user -> Ok (Never_set_up base_path)
     | Boot_after_off (_ : Authz_state.t) | Boot_multi_account ->
       (* The input names no mode event, so the table reads neither an Off nor
          an active installation. *)
       Error (tool_refused, [])
     | Stop stop -> Error (messages input stop))
;;
