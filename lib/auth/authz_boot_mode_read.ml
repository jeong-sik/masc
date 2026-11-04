(* HIGH-RISK-UNREVIEWED: this module reads what the boot judgment of the account
   mode decides on. Reading a file that is there as absent boots a rolled-back
   multi-account installation as a single user. *)

module B = Authz_boot_mode
module H = Authz_high_water
module I = Authz_install_record
module L = Authz_log
module M = Authz_mode_event
module R = Authz_record
module S = Authz_external_store

(* The directory under the config home, and the member of config.json. *)
let config_subdir = "masc"
let member_name = "account_mode"

let config_dir ~xdg_config_home ~home =
  let absolute = function
    | Some dir when (not (String.equal dir "")) && not (Filename.is_relative dir) -> Some dir
    | Some _ | None -> None
  in
  match absolute xdg_config_home, home with
  | Some dir, (Some _ | None) -> Some (Filename.concat dir config_subdir)
  | None, Some home when not (String.equal home "") ->
    Some (Filename.concat (Filename.concat home ".config") config_subdir)
  | None, (Some _ | None) -> None
;;

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
  match Auth_credential_base.credential_path_exists file with
  | Error error -> absent (Masc_domain.masc_error_to_string error)
  | Ok false -> B.Not_set, settings_of Masc_domain.default_auth_config
  | Ok true ->
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

(* What the fold over the log keeps: the probe of the high-water mark, the last
   mode event, and how many records it saw. *)
type fold =
  { probe : H.Probe.t
  ; last : M.event option
  ; records : int
  }

let step acc (record : R.t) =
  let probe = H.Probe.add acc.probe record in
  let records = acc.records + 1 in
  match record.R.kind with
  | R.Kind.Mode_event ->
    (match M.of_body record.R.body with
     | Ok event -> Ok { probe; last = Some event.M.event; records }
     | Error error -> Error error)
  | R.Kind.Runtime_grant
  | R.Kind.Delegate_policy
  | R.Kind.Principal
  | R.Kind.Internal_service_credential
  | R.Kind.Permission_revocation
  | R.Kind.Trigger_evidence
  | R.Kind.Lease_terminal_evidence
  | R.Kind.Preauthorized_expiry
  | R.Kind.Migration_diagnostic
  | R.Kind.Local_recovery -> Ok { acc with probe; records }
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
       (match S.open_at_start ~path ~init:S.State.empty ~step:S.apply with
        | Error error -> Error (S.open_error_to_string S.violation_to_string error)
        | Ok (_store, _state, { S.contents = S.Missing; _ }) -> Ok None
        | Ok (_store, state, { S.contents = S.Empty | S.Lines _; _ }) -> Ok (Some state)))
;;

let read_log_and_store ~base_path ~config_dir =
  let store = store_state ~config_dir ~base_path in
  let state =
    match store with
    | Ok (Some state) -> state
    | Ok None | Error _ -> S.State.empty
  in
  let log =
    L.open_at_start
      ~path:(L.path_of_base_path ~base_path)
      ~init:{ probe = H.Probe.create state; last = None; records = 0 }
      ~step
  in
  let log_mode =
    match log with
    | Error error -> B.Log_unreadable (L.open_error_to_string M.error_to_string error)
    | Ok (_log, { last = Some event; _ }, _recovered) -> B.made_by event
    | Ok (_log, { last = None; records = 0; _ }, _recovered) -> B.No_mode_event
    | Ok (_log, { last = None; records; _ }, _recovered) ->
      (* A Fresh_bootstrap is the first record of every log (design 5.1). *)
      B.Log_unreadable
        (Printf.sprintf "it holds %d records and no mode event, and only a mode event starts it" records)
  in
  let high_water =
    match store, log with
    | Error detail, (Ok _ | Error _) -> B.Store_unreadable detail
    | Ok None, (Ok _ | Error _) -> B.Judged H.Absent
    | Ok (Some _), Ok (_log, fold, _recovered) -> B.Judged (H.judge fold.probe)
    | Ok (Some _), Error _ ->
      B.Store_unreadable "it was not judged, because the authorization log cannot be read"
  in
  log_mode, high_water
;;

let input ~base_path ~config_dir ~anonymous_mutations =
  let requested, settings = read_config ~base_path in
  let log_mode, high_water = read_log_and_store ~base_path ~config_dir in
  { B.requested; log_mode; high_water; settings; anonymous_mutations }
;;

type decision =
  | Boot_single_user
  | Refuse of B.refusal * B.refusal list
  | Multi_account_not_activatable
  | Multi_account_not_served of B.mode

let decide input =
  match B.judge input with
  | Ok B.Single_user -> Boot_single_user
  | Ok B.Activation_requested -> Multi_account_not_activatable
  | Ok ((B.Multi_account | B.Multi_account_uncertain) as mode) -> Multi_account_not_served mode
  | Error (first, rest) -> Refuse (first, rest)
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
  | Boot_single_user -> []
  | Refuse (first, rest) -> List.map B.refusal_to_string (first :: rest)
  | Multi_account_not_activatable ->
    [ "config.json asks for Multi_account and nothing is set up yet; this server has no \
       host-local bootstrap to activate it (Multi_account_not_activatable)"
    ]
  | Multi_account_not_served mode ->
    Printf.sprintf
      "the authorization log made Multi_account (%s); this server does not have the account \
       layers that serve it"
      (B.mode_to_string mode)
    :: high_water_detail input.high_water
;;
