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

(* The file is read once, and the member and the other fields come from the
   same bytes. *)
let read_config ~base_path =
  let file = Auth_credential_base.auth_config_file base_path in
  let absent detail =
    Log.Auth.warn "%s is read as absent for the account mode: %s" file detail;
    B.Not_set, B.Settings_unreadable detail
  in
  match P.of_path file with
  | P.Cannot_check detail -> absent detail
  | P.Not_there -> B.Not_set, settings_of Masc_domain.default_auth_config
  | P.There ->
    (match Auth_credential_base.read_regular_auth_file file with
     | Error error -> absent (Masc_domain.masc_error_to_string error)
     | Ok content ->
       (match Yojson.Safe.from_string content with
        | exception Yojson.Json_error detail -> absent ("not JSON: " ^ detail)
        | `Assoc _ as json ->
          let settings =
            match Masc_domain.auth_config_of_yojson json with
            | Ok config -> settings_of config
            | Error detail -> B.Settings_unreadable detail
          in
          requested_of_json json, settings
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json ->
          absent ("not a JSON object: " ^ Yojson.Safe.to_string json)))
;;

(* What the fold over the log keeps: the probe of the high-water mark and the
   state of the records. *)
type fold =
  { probe : H.Probe.t
  ; state : Authz_state.t
  }

let step acc (record : R.t) =
  match Authz_state.step acc.state record with
  | Ok state -> Ok { probe = H.Probe.add acc.probe record; state }
  | Error refusal -> Error refusal
;;

(* The state of the external store that the install record names. [None] when
   there is no config directory, no record, or no store where the record points
   (design 8.4). *)
let store_state ~config_dir ~base_path : (S.State.t option, string) result =
  match I.locate ~config_dir ~base_path with
  | Error error -> Error (I.locate_error_to_string error)
  | Ok located ->
    (match I.read located with
     | Error error -> Error (I.read_error_to_string error)
     | Ok None -> Ok None
     | Ok (Some path) ->
       (match P.of_path path with
        | P.Not_there -> Ok None
        | P.Cannot_check detail -> Error (Printf.sprintf "the external store %s: %s" path detail)
        | P.There ->
          (match S.open_at_start ~path ~init:S.State.empty ~step:S.apply with
           | Error error -> Error (S.open_error_to_string S.violation_to_string error)
           | Ok (_store, _state, { S.contents = S.Missing; _ }) -> Ok None
           | Ok (_store, state, { S.contents = S.Empty | S.Lines _; _ }) -> Ok (Some state))))
;;

(* The log as the boot found it. Whether the log or the store is there is read
   before the lock of its file is taken, so this needs every process that
   creates either file to hold the BasePath lease, as the boot does. *)
type log_read =
  | Log_not_there
  | Log_cannot_check of string
  | Log_opened of (fold, string) result

let read_log ~base_path ~state =
  let path = L.path_of_base_path ~base_path in
  match P.of_path path with
  | P.Not_there -> Log_not_there
  | P.Cannot_check detail -> Log_cannot_check (Printf.sprintf "%s: %s" path detail)
  | P.There ->
    (match
       L.open_at_start ~path ~init:{ probe = H.Probe.create state; state = Authz_state.empty } ~step
     with
     | Error error -> Log_opened (Error (L.open_error_to_string Authz_state.refusal_to_string error))
     | Ok (_log, fold, _recovered) -> Log_opened (Ok fold))
;;

let read_log_and_store ~base_path ~config_dir =
  let store = store_state ~config_dir ~base_path in
  let state =
    match store with
    | Ok (Some state) -> state
    | Ok None | Error _ -> S.State.empty
  in
  let log = read_log ~base_path ~state in
  let log_mode =
    match log with
    | Log_not_there -> B.No_mode_event
    | Log_cannot_check detail | Log_opened (Error detail) -> B.Log_unreadable detail
    | Log_opened (Ok fold) -> B.of_mode_state fold.state.Authz_state.mode
  in
  let high_water =
    match store, log with
    | Error detail, (Log_not_there | Log_cannot_check _ | Log_opened _) -> B.Store_unreadable detail
    | Ok None, (Log_not_there | Log_cannot_check _ | Log_opened _) -> B.Judged H.Absent
    | Ok (Some _), Log_opened (Ok fold) -> B.Judged (H.judge fold.probe)
    | Ok (Some state), Log_not_there -> B.Judged (H.judge (H.Probe.create state))
    | Ok (Some _), (Log_cannot_check _ | Log_opened (Error _)) ->
      B.Store_unreadable "it was not judged, because the authorization log cannot be read"
  in
  log_mode, high_water
;;

let input ~base_path ~config_dir ~anonymous_mutations =
  let requested, settings = read_config ~base_path in
  let log_mode, high_water = read_log_and_store ~base_path ~config_dir in
  { B.requested; log_mode; high_water; settings; anonymous_mutations }
;;

type stop =
  | Refuse of B.refusal * B.refusal list
  | Multi_account_not_activatable
  | Multi_account_not_served of B.mode

type decision =
  | Boot_single_user
  | Stop of stop

let decide input =
  match B.judge input with
  | Ok B.Single_user -> Boot_single_user
  | Ok B.Activation_requested -> Stop Multi_account_not_activatable
  | Ok ((B.Multi_account | B.Multi_account_uncertain) as mode) ->
    Stop (Multi_account_not_served mode)
  | Error (first, rest) -> Stop (Refuse (first, rest))
;;

let high_water_detail = function
  | B.Store_unreadable detail -> [ "the external store cannot be read: " ^ detail ]
  | B.Judged (H.Mismatch (first, rest)) ->
    List.map
      (fun reason ->
        "the external store does not match the authorization log: " ^ H.reason_to_string reason)
      (first :: rest)
  | B.Judged (H.Absent | H.Matches) -> []
;;

let messages (input : B.input) = function
  | Refuse (first, rest) -> B.refusal_to_string first, List.map B.refusal_to_string rest
  | Multi_account_not_activatable ->
    ( "config.json asks for Multi_account and nothing is set up yet; this server has no \
       host-local bootstrap to activate it (Multi_account_not_activatable)"
    , [] )
  | Multi_account_not_served mode ->
    ( Printf.sprintf
        "the authorization log made Multi_account (%s); this server does not have the account \
         layers that serve it"
        (B.mode_to_string mode)
    , high_water_detail input.high_water )
;;

let boot ~base_path ~config_dir ~anonymous_mutations =
  let input = input ~base_path ~config_dir ~anonymous_mutations in
  match decide input with
  | Boot_single_user -> Ok ()
  | Stop stop -> Error (messages input stop)
;;
