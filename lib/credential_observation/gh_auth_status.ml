type source_kind =
  | Environment_variable of string
  | Stored_credential
  | No_token_found

type row =
  { host : string
  ; state : string
  ; active : bool
  ; login : string option
  ; token_source_label : string
  ; source : source_kind option
  ; scopes : string list option
  ; error : string option
  }

type verdict =
  | Authenticated
  | Unauthenticated
  | Shadowed
  | Unknown

type host_status =
  { host : string
  ; verdict : verdict
  ; rows : row list
  }

type t =
  { hosts : host_status list
  ; undecodable : string option
  }

let hosts_field = "hosts"
let state_success = "success"
let keyring_label = "keyring"
let no_token_label = "default"

(* go-gh resolves a token from exactly these variables before consulting stored
   credentials (cli/go-gh auth.TokenForHost). The set is closed there, so it is
   closed here; anything else is left uninterpreted rather than assumed stored. *)
let environment_labels =
  [ "GH_TOKEN"; "GITHUB_TOKEN"; "GH_ENTERPRISE_TOKEN"; "GITHUB_ENTERPRISE_TOKEN" ]
;;

let verdict_to_string = function
  | Authenticated -> "authenticated"
  | Unauthenticated -> "unauthenticated"
  | Shadowed -> "shadowed"
  | Unknown -> "unknown"
;;

(* A sound-partial read. [None] is "this parser does not know", never a
   harmless default: an unrecognised label could name a variable, and calling
   it stored is the one direction that hides a shadow. *)
let source_kind_of_label label =
  if List.exists (String.equal label) environment_labels
  then Some (Environment_variable label)
  else if String.equal label keyring_label
  then Some Stored_credential
  else if String.equal label no_token_label
  then Some No_token_found
  else if Filename.is_relative label
  then None
  else
    (* gh names a config-file source by absolute path, e.g.
       "/Users/x/.config/gh/hosts.yml". *)
    Some Stored_credential
;;

(* gh emits scopes as one comma-separated string, absent when the token has
   none to report. *)
let scopes_of_string value =
  String.split_on_char ',' value
  |> List.map String.trim
  |> List.filter (fun scope -> not (String.equal scope ""))
;;

let row_of_json ~host json =
  match Json_util.get_string json "tokenSource" with
  | None -> None
  | Some token_source_label ->
    Some
      { host
      ; state = Option.value (Json_util.get_string json "state") ~default:""
      ; active = Option.value (Json_util.get_bool json "active") ~default:false
      ; login = Json_util.get_string_nonempty json "login"
      ; token_source_label
      ; source = source_kind_of_label token_source_label
      ; scopes = Option.map scopes_of_string (Json_util.get_string json "scopes")
      ; error = Json_util.get_string_nonempty json "error"
      }
;;

let is_environment row =
  match row.source with
  | Some (Environment_variable _) -> true
  | Some (Stored_credential | No_token_found) | None -> false
;;

let is_stored row =
  match row.source with
  | Some Stored_credential -> true
  | Some (Environment_variable _ | No_token_found) | None -> false
;;

(* Scoped to one host. The shadow question is "which credential does gh use for
   THIS host", so a keyring row on github.com and a variable row on an
   enterprise host are two independent answers, not a shadow. *)
let verdict_of_rows rows =
  let unrecognised = List.exists (fun row -> Option.is_none row.source) rows in
  let active_rows = List.filter (fun row -> row.active) rows in
  if unrecognised
  then Unknown
  else if List.exists is_environment rows && List.exists is_stored rows
  then Shadowed
  else (
    match active_rows with
    | [ active ] ->
      if String.equal active.state state_success then Authenticated else Unauthenticated
    | [] | _ :: _ :: _ ->
      (* gh marks exactly one row active per host. Neither zero nor several is
         a state to guess through. *)
      Unknown)
;;

let rows_of_json ~host rows_json =
  (match rows_json with
   | `List rows -> rows
   | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> [])
  |> List.filter_map (row_of_json ~host)
;;

let decode payload =
  match Yojson.Safe.from_string payload with
  | exception Yojson.Json_error detail -> { hosts = []; undecodable = Some detail }
  | json ->
    (match Safe_ops.json_member_opt hosts_field json with
     | None -> { hosts = []; undecodable = Some "payload carries no hosts object" }
     | Some `Assoc [] -> { hosts = []; undecodable = None }
     | Some (`Assoc entries) ->
       let hosts =
         List.map
           (fun (host, rows_json) ->
              let rows = rows_of_json ~host rows_json in
              { host; verdict = verdict_of_rows rows; rows })
           entries
       in
       { hosts; undecodable = None }
     | Some (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) ->
       { hosts = []; undecodable = Some "hosts field is not an object" })
;;
