type claude_code = |
type codex = |

type _ client =
  | Claude_code : claude_code client
  | Codex : codex client

type source =
  | Declared_directory
  | Inherited_directory
  | Inherited_user_home

type 'client t =
  { client : 'client client
  ; home : string
  ; source : source
  ; key_file : string option
  ; environment : string array
  ; asked_names : string list
  }

type 'client selection =
  | Current of string option
  | Captured of 'client t

module Names = Set.Make (String)

let validate_environment environment =
  Array.fold_left (fun result entry ->
    let ( let* ) = Result.bind in
    let* seen = result in
    if String.contains entry '\000' then Error "captured environment contains a NUL byte"
    else match String.index_opt entry '=' with
      | None | Some 0 -> Error "captured environment contains an invalid entry"
      | Some index ->
        let name = String.sub entry 0 index in
        if Names.mem name seen then Error "captured environment contains a duplicate name"
        else Ok (Names.add name seen)) (Ok Names.empty) environment
  |> Result.map (fun _ -> ())

let default_directory : type owner. owner client -> string = function
  | Claude_code -> ".claude"
  | Codex -> ".codex"

let value name environment =
  let prefix = name ^ "=" in
  environment |> Array.to_list |> List.find_map (fun entry ->
    if String.starts_with ~prefix entry
    then Some (String.sub entry (String.length prefix)
      (String.length entry - String.length prefix))
    else None)

let directory_variable : type owner. owner client -> string = function
  | Claude_code -> "CLAUDE_CONFIG_DIR"
  | Codex -> "CODEX_HOME"

let selected_directory (type owner) ~(client : owner client) ~declaration ~environment =
  let ( let* ) = Result.bind in
  match declaration with
  | Some home ->
    let* home = Runtime_account_home.of_string home in
    Ok (Declared_directory, home)
  | None ->
    let source, path = match value (directory_variable client) environment with
      | Some path when path <> "" -> Inherited_directory, Some path
      | Some _ | None -> Inherited_user_home,
        (match value "HOME" environment with
         | Some home when home <> "" -> Some (Filename.concat home (default_directory client))
         | Some _ | None -> None) in
    let* path = match path with
      | Some path -> Ok path
      | None -> Error "official client context has no selected home" in
    let* home = match client with
      | Claude_code ->
        (match source with
         | Inherited_directory -> Runtime_account_home.of_inherited path
         | Inherited_user_home | Declared_directory -> Runtime_account_home.of_string path)
      | Codex ->
        let path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
        Runtime_account_home.of_string path in
    Ok (source, home)

let resolve_home ~client ~declaration =
  selected_directory ~client ~declaration ~environment:(Unix.environment ())
  |> Result.map snd

let codex_configured_keys home =
  let path = Filename.concat home "config.toml" in
  if not (Sys.file_exists path) then Ok [] else
  try
    let ( let* ) = Result.bind in
    let body = In_channel.with_open_bin path In_channel.input_all in
    let* projected = Runtime_verification_codex_home.project_config body in
    let toml = Otoml.Parser.from_string projected in
    let table = function
      | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> fields
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
        raise (Invalid_argument "table") in
    let env_name = function
      | Otoml.TomlString name when String.length name > 0 ->
        let initial = function 'a'..'z' | 'A'..'Z' | '_' -> true | _ -> false in
        if initial name.[0] && String.for_all
          (function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false) name
        then name else raise (Invalid_argument "environment name")
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
      | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
        raise (Invalid_argument "environment name") in
    let providers = match Otoml.find_opt toml Fun.id ["model_providers"] with
      | None -> [] | Some value -> table value in
    let names = List.concat_map (fun (_, provider) ->
      let fields = table provider in
      let key = match List.assoc_opt "env_key" fields with
        | None -> [] | Some value -> [env_name value] in
      let headers = match List.assoc_opt "env_http_headers" fields with
        | None -> [] | Some value -> List.map (fun (_, value) -> env_name value) (table value) in
      key @ headers) providers in
    Ok (List.sort_uniq String.compare names)
  with Otoml.Parse_error _ | Otoml.Type_error _ | Sys_error _ | Invalid_argument _ ->
    Error "Cannot read declared Codex provider credential environment names; inspect config.toml"

(* The entries a Claude Code child takes from the environment of the server
   under [names]. A home the environment chose stays chosen: the child gets
   the spelling this capture read. *)
let claude_inherited ~names ~source ~home inherited =
  List.filter_map (fun name ->
    let selected = if name = "CLAUDE_CONFIG_DIR" && source = Inherited_directory
      then Some home else value name inherited in
    Option.map (fun value -> name ^ "=" ^ value) selected) names

let capture (type owner) ~(client : owner client) ~declaration : (owner t, string) result =
  let inherited = Unix.environment () in
  let ( let* ) = Result.bind in
  let* source, home = selected_directory ~client ~declaration ~environment:inherited in
  let* environment, asked_names = match client with
    | Claude_code ->
      let names = Runtime_claude_environment_projection.inherited_names
        ~explicit_account:(Option.is_some declaration) in
      Ok (Runtime_claude_environment_projection.of_inherited
        ~account_home:(Option.map (fun _ -> home) declaration)
        (claude_inherited ~names ~source ~home inherited), [])
    | Codex ->
      let* configured = codex_configured_keys home in
      Ok (Runtime_codex_environment_projection.project
        ~explicit_account:(Option.is_some declaration) ~home:(Some home) ~configured inherited,
        configured) in
  let* () = validate_environment environment in
  Ok {client; home; source; key_file = None; environment = Array.copy environment; asked_names}

type key_capture_error =
  | Key_not_read of Runtime_api_key_file.read_error
  | Key_not_captured of string

(* The capture reads the file itself, so the file an account says its key is
   of is the file its key came from. *)
let capture_on_key ~declaration ~key_file =
  let ( let* ) = Result.bind in
  let captured key =
    let inherited = Unix.environment () in
    let* source, home =
      selected_directory ~client:Claude_code ~declaration ~environment:inherited in
    (* The names a declared account keeps, whether or not a home is declared:
       no credential, provider choice or endpoint of the server stays beside
       the key. *)
    let kept = Runtime_claude_environment_projection.inherited_names ~explicit_account:true in
    let names = match source with
      | Inherited_directory -> directory_variable Claude_code :: kept
      | Declared_directory | Inherited_user_home -> kept in
    let environment =
      Array.append
        (Runtime_claude_environment_projection.of_inherited
           ~account_home:(Option.map (fun _ -> home) declaration)
           (claude_inherited ~names ~source ~home inherited))
        [| Runtime_claude_environment_projection.api_key_variable
           ^ "=" ^ Runtime_api_key_file.value key |] in
    let* () = validate_environment environment in
    Ok {client = Claude_code; home; source; key_file = Some key_file; environment;
        asked_names = []} in
  match Runtime_api_key_file.read key_file with
  | Error error -> Error (Key_not_read error)
  | Ok key -> Result.map_error (fun detail -> Key_not_captured detail) (captured key)

let private_codex_environment ~home selected =
  let ( let* ) = Result.bind in
  let* home = Runtime_account_home.of_string home in
  let* configured = codex_configured_keys home in
  let environment = Runtime_codex_environment_projection.project ~explicit_account:true
    ~home:(Some home) ~configured selected.environment in
  let* () = validate_environment environment in
  Ok environment

let home selected = selected.home
let client selected = selected.client
let source selected = selected.source
let key_file selected = selected.key_file
let names_asked_by_the_home selected = selected.asked_names
let environment selected = Array.copy selected.environment
let environment_value selected name = value name selected.environment
let same left right =
  String.equal left.home right.home
  && left.source = right.source
  && Option.equal String.equal left.key_file right.key_file
  && List.equal String.equal left.asked_names right.asked_names
  && List.equal String.equal
       (List.sort String.compare (Array.to_list left.environment))
       (List.sort String.compare (Array.to_list right.environment))
