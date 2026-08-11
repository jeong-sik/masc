type token_source =
  | Keyring
  | Environment of string
  | Config_file of string

type outcome =
  | Logged_in
  | Login_failed
  | Timed_out

type entry =
  { outcome : outcome
  ; host : string
  ; account : string option
  ; source_label : string
  ; source : token_source
  ; active : bool
  ; scopes : string list option
  ; git_protocol : [ `Https | `Ssh ]
  ; error : string option
  }

type verdict =
  | Authenticated
  | Unauthenticated
  | Shadowed
  | Unknown

type t =
  { entries : entry list
  ; schema_error : string option
  }

let ( let* ) = Result.bind

let verdict_to_string = function
  | Authenticated -> "authenticated"
  | Unauthenticated -> "unauthenticated"
  | Shadowed -> "shadowed"
  | Unknown -> "unknown"
;;

let command_argv ~hostname =
  [| "gh"; "auth"; "status"; "--hostname"; hostname; "--json"; "hosts" |]
;;

let object_fields context = function
  | `Assoc fields -> Ok fields
  | json ->
    Error
      (Printf.sprintf
         "%s must be an object, got %s"
         context
         (Yojson.Safe.to_string json))
;;

let list_items context = function
  | `List items -> Ok items
  | json ->
    Error
      (Printf.sprintf
         "%s must be an array, got %s"
         context
         (Yojson.Safe.to_string json))
;;

let exact_fields ~context ~required ~optional fields =
  let expected = List.sort_uniq String.compare (required @ optional) in
  let actual = List.map fst fields in
  let unique = List.sort_uniq String.compare actual in
  let missing = List.filter (fun name -> not (List.mem name unique)) required in
  let unknown = List.filter (fun name -> not (List.mem name expected)) unique in
  let duplicate_count = List.length actual - List.length unique in
  match missing, unknown, duplicate_count with
  | [], [], 0 -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "%s fields mismatch (missing=[%s], unknown=[%s], duplicates=%d)"
         context
         (String.concat "," missing)
         (String.concat "," unknown)
         duplicate_count)
;;

let field context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is missing %s" context name)
;;

let string_field context name fields =
  let* value = field context name fields in
  match value with
  | `String value -> Ok value
  | json ->
    Error
      (Printf.sprintf
         "%s.%s must be a string, got %s"
         context
         name
         (Yojson.Safe.to_string json))
;;

let bool_field context name fields =
  let* value = field context name fields in
  match value with
  | `Bool value -> Ok value
  | json ->
    Error
      (Printf.sprintf
         "%s.%s must be a boolean, got %s"
         context
         name
         (Yojson.Safe.to_string json))
;;

let optional_string_field context name fields =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some json ->
    Error
      (Printf.sprintf
         "%s.%s must be a string when present, got %s"
         context
         name
         (Yojson.Safe.to_string json))
;;

let account_of_login login =
  match String.trim login with
  | "" -> None
  | value -> Some value
;;

let scopes_of_header = function
  | None -> None
  | Some header ->
    Some
      (String.split_on_char ',' header
       |> List.map String.trim
       |> List.filter (fun scope -> scope <> ""))
;;

let source_of_label label =
  if String.equal label "keyring"
  then Ok Keyring
  else if String.ends_with ~suffix:"_TOKEN" label
  then Ok (Environment label)
  else if
    String.ends_with ~suffix:"/hosts.yml" label
    || String.ends_with ~suffix:"\\hosts.yml" label
  then Ok (Config_file label)
  else Error (Printf.sprintf "unknown gh tokenSource %S" label)
;;

let outcome_of_state = function
  | "success" -> Ok Logged_in
  | "error" -> Ok Login_failed
  | "timeout" -> Ok Timed_out
  | state -> Error (Printf.sprintf "unknown gh auth state %S" state)
;;

let git_protocol_of_string = function
  | "https" -> Ok `Https
  | "ssh" -> Ok `Ssh
  | protocol -> Error (Printf.sprintf "unknown gh gitProtocol %S" protocol)
;;

let parse_entry ~map_host ~index json =
  let context = Printf.sprintf "hosts.%s[%d]" map_host index in
  let* fields = object_fields context json in
  let* () =
    exact_fields
      ~context
      ~required:[ "active"; "gitProtocol"; "host"; "login"; "state"; "tokenSource" ]
      ~optional:[ "error"; "scopes" ]
      fields
  in
  let* state = string_field context "state" fields in
  let* outcome = outcome_of_state state in
  let* active = bool_field context "active" fields in
  let* host = string_field context "host" fields in
  let* () =
    if String.equal (String.lowercase_ascii host) (String.lowercase_ascii map_host)
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s.host %S does not match map key %S"
           context
           host
           map_host)
  in
  let* login = string_field context "login" fields in
  let* source_label = string_field context "tokenSource" fields in
  let* source = source_of_label source_label in
  let* git_protocol_raw = string_field context "gitProtocol" fields in
  let* git_protocol = git_protocol_of_string git_protocol_raw in
  let* scopes = optional_string_field context "scopes" fields in
  let* error = optional_string_field context "error" fields in
  let* () =
    match outcome, error with
    | Logged_in, Some _ -> Error (context ^ " success unexpectedly carries error")
    | (Login_failed | Timed_out), None ->
      Error (context ^ " failed state is missing error")
    | Logged_in, None | (Login_failed | Timed_out), Some _ -> Ok ()
  in
  Ok
    { outcome
    ; host
    ; account = account_of_login login
    ; source_label
    ; source
    ; active
    ; scopes = scopes_of_header scopes
    ; git_protocol
    ; error
    }
;;

let parse_host_entries (map_host, json) =
  let* items = list_items ("hosts." ^ map_host) json in
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* entry = parse_entry ~map_host ~index item in
      loop (index + 1) (entry :: acc) rest
  in
  loop 0 [] items
;;

let parse_json json =
  let* root = object_fields "root" json in
  let* () = exact_fields ~context:"root" ~required:[ "hosts" ] ~optional:[] root in
  let* hosts_json = field "root" "hosts" root in
  let* hosts = object_fields "hosts" hosts_json in
  let host_names = List.map fst hosts in
  if List.length host_names <> List.length (List.sort_uniq String.compare host_names)
  then Error "hosts contains a duplicate hostname"
  else
    let rec loop acc = function
      | [] -> Ok (List.rev acc |> List.concat)
      | host :: rest ->
        let* entries = parse_host_entries host in
        loop (entries :: acc) rest
    in
    loop [] hosts
;;

let parse output =
  match
    try Ok (Yojson.Safe.from_string output) with
    | Yojson.Json_error detail -> Error ("invalid gh auth JSON: " ^ detail)
  with
  | Error detail -> { entries = []; schema_error = Some detail }
  | Ok json ->
    (match parse_json json with
     | Ok entries -> { entries; schema_error = None }
     | Error detail -> { entries = []; schema_error = Some detail })
;;

let is_environment = function
  | Environment _ -> true
  | Keyring | Config_file _ -> false
;;

let verdict_for_host parsed ~hostname =
  match parsed.schema_error with
  | Some _ -> Unknown
  | None ->
    let hostname = String.lowercase_ascii hostname in
    let entries =
      List.filter
        (fun entry -> String.equal (String.lowercase_ascii entry.host) hostname)
        parsed.entries
    in
    (match List.filter (fun entry -> entry.active) entries with
     | [] when entries = [] -> Unauthenticated
     | [ active ] ->
       if
         is_environment active.source
         && List.exists (fun entry -> not (is_environment entry.source)) entries
       then Shadowed
       else
         (match active.outcome with
          | Logged_in -> Authenticated
          | Login_failed -> Unauthenticated
          | Timed_out -> Unknown)
     | [] | _ :: _ :: _ -> Unknown)
;;
