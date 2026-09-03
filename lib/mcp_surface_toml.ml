(* See mcp_surface_toml.mli. *)

let sprintf = Printf.sprintf
let ( let* ) = Result.bind

(* ── TOML value accessors ─────────────────────────────────────────────── *)

let toml_shape = function
  | Otoml.TomlString _ -> "a string"
  | Otoml.TomlInteger _ -> "an integer"
  | Otoml.TomlFloat _ -> "a float"
  | Otoml.TomlBoolean _ -> "a boolean"
  | Otoml.TomlOffsetDateTime _ -> "an offset datetime"
  | Otoml.TomlLocalDateTime _ -> "a local datetime"
  | Otoml.TomlLocalDate _ -> "a local date"
  | Otoml.TomlLocalTime _ -> "a local time"
  | Otoml.TomlArray _ -> "an array"
  | Otoml.TomlTable _ -> "a table"
  | Otoml.TomlInlineTable _ -> "an inline table"
  | Otoml.TomlTableArray _ -> "an array of tables"
;;

let as_non_empty_string ~context = function
  | Otoml.TomlString value ->
    if String.equal (String.trim value) ""
    then Error (sprintf "%s must not be empty" context)
    else Ok value
  | ( Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a string, got %s" context (toml_shape other))
;;

let as_bool ~context = function
  | Otoml.TomlBoolean value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a boolean, got %s" context (toml_shape other))
;;

let as_table_pairs ~context = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> Ok pairs
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) as other ->
    Error (sprintf "%s must be a table, got %s" context (toml_shape other))
;;

let as_table_array ~context = function
  | Otoml.TomlTableArray tables -> Ok tables
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ) as other ->
    Error (sprintf "%s must be an array of tables, got %s" context (toml_shape other))
;;

let required_string ~context pairs key =
  match List.assoc_opt key pairs with
  | None -> Error (sprintf "%s is missing the required key %S" context key)
  | Some value -> as_non_empty_string ~context:(sprintf "%s.%s" context key) value
;;

let only_known_keys ~context allowed pairs =
  let rec walk = function
    | [] -> Ok ()
    | (key, (_ : Otoml.t)) :: rest ->
      if List.exists (String.equal key) allowed
      then walk rest
      else Error (sprintf "%s: unknown key %S" context key)
  in
  walk pairs
;;

(* ── resources.toml ───────────────────────────────────────────────────── *)

type resource_entry =
  { uri : string
  ; name : string
  ; title : string
  ; description : string
  ; mime_type : string
  }

type template_entry =
  { uri_template : string
  ; name : string
  ; title : string
  ; description : string
  ; mime_type : string
  }

let text_keys = [ "name"; "title"; "description"; "mime_type" ]

let entry_text_of_pairs ~context pairs =
  let* name = required_string ~context pairs "name" in
  let* title = required_string ~context pairs "title" in
  let* description = required_string ~context pairs "description" in
  let* mime_type = required_string ~context pairs "mime_type" in
  Ok (name, title, description, mime_type)
;;

let resource_of_pairs ~context pairs =
  let* uri = required_string ~context pairs "uri" in
  let* name, title, description, mime_type = entry_text_of_pairs ~context pairs in
  let* () = only_known_keys ~context ("uri" :: text_keys) pairs in
  Ok { uri; name; title; description; mime_type }
;;

let template_of_pairs ~context pairs =
  let* uri_template = required_string ~context pairs "uri_template" in
  let* name, title, description, mime_type = entry_text_of_pairs ~context pairs in
  let* () = only_known_keys ~context ("uri_template" :: text_keys) pairs in
  Ok { uri_template; name; title; description; mime_type }
;;

let entries_of_value ~context ~element value =
  let* tables = as_table_array ~context value in
  let rec collect index acc = function
    | [] -> Ok (List.rev acc)
    | table :: rest ->
      let element_context = sprintf "%s[%d]" context index in
      let* pairs = as_table_pairs ~context:element_context table in
      let* parsed = element ~context:element_context pairs in
      collect (index + 1) (parsed :: acc) rest
  in
  collect 0 [] tables
;;

type surface =
  { server_description : string
  ; tool_help_name_suffix : string
  ; resources : resource_entry list
  ; resource_templates : template_entry list
  }

let surface_of_pairs pairs =
  let* server_description =
    match List.assoc_opt "server" pairs with
    | None -> Error "missing the required table [server]"
    | Some value ->
      let* server = as_table_pairs ~context:"server" value in
      let* description = required_string ~context:"server" server "description" in
      let* () = only_known_keys ~context:"server" [ "description" ] server in
      Ok description
  in
  let* tool_help_name_suffix =
    match List.assoc_opt "tool_help" pairs with
    | None -> Error "missing the required table [tool_help]"
    | Some value ->
      let* tool_help = as_table_pairs ~context:"tool_help" value in
      (* The suffix is a single space plus a word: leading whitespace is the
         payload here, so the general non-empty check (which trims) is not
         enough -- an all-whitespace suffix would pass it and compose into
         names like ["masc_status "]. *)
      let* suffix =
        match List.assoc_opt "name_suffix" tool_help with
        | None -> Error "tool_help is missing the required key \"name_suffix\""
        | Some (Otoml.TomlString suffix) ->
          if String.length suffix >= 2 && not (String.equal (String.trim suffix) "")
          then Ok suffix
          else Error "tool_help.name_suffix must be at least two characters and not all whitespace"
        | Some other ->
          Error
            (sprintf "tool_help.name_suffix must be a string, got %s" (toml_shape other))
      in
      let* () = only_known_keys ~context:"tool_help" [ "name_suffix" ] tool_help in
      Ok suffix
  in
  let* resources =
    match List.assoc_opt "resources" pairs with
    | None -> Error "missing the required [[resources]] array"
    | Some value ->
      entries_of_value ~context:"resources" ~element:resource_of_pairs value
  in
  let* resource_templates =
    match List.assoc_opt "resource_templates" pairs with
    | None -> Error "missing the required [[resource_templates]] array"
    | Some value ->
      entries_of_value
        ~context:"resource_templates"
        ~element:template_of_pairs
        value
  in
  let* () =
    only_known_keys
      ~context:"resources.toml"
      [ "server"; "tool_help"; "resources"; "resource_templates" ]
      pairs
  in
  Ok { server_description; tool_help_name_suffix; resources; resource_templates }
;;

let load_resources ~contents =
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error (sprintf "mcp/resources.toml: TOML parse error: %s" message)
  | Ok (Otoml.TomlTable pairs) ->
    (match surface_of_pairs pairs with
     | Ok surface -> Ok surface
     | Error message -> Error (sprintf "mcp/resources.toml: %s" message))
  | Ok
      ( ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
        | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
        | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
        | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
        | Otoml.TomlTableArray _ ) as other ) ->
    Error (sprintf "mcp/resources.toml: top level must be a table, got %s" (toml_shape other))
;;

(* ── prompts.toml ─────────────────────────────────────────────────────── *)

type prompt_argument =
  { argument_name : string
  ; argument_description : string
  ; argument_required : bool
  }

type prompt_entry =
  { prompt_name : string
  ; prompt_title : string
  ; prompt_description : string
  ; prompt_arguments : prompt_argument list
  }

let prompt_argument_of_pairs ~context pairs =
  let* name = required_string ~context pairs "name" in
  let* description = required_string ~context pairs "description" in
  let* required =
    match List.assoc_opt "required" pairs with
    | None -> Ok false
    | Some value -> as_bool ~context:(sprintf "%s.required" context) value
  in
  let* () =
    only_known_keys ~context [ "name"; "description"; "required" ] pairs
  in
  Ok
    { argument_name = name
    ; argument_description = description
    ; argument_required = required
    }
;;

let prompt_of_pairs ~context pairs =
  let* name = required_string ~context pairs "name" in
  let context = sprintf "%s (%s)" context name in
  let* title = required_string ~context pairs "title" in
  let* description = required_string ~context pairs "description" in
  let* arguments =
    match List.assoc_opt "arguments" pairs with
    | None -> Ok []
    | Some value ->
      entries_of_value
        ~context:(sprintf "%s.arguments" context)
        ~element:prompt_argument_of_pairs
        value
  in
  let* () =
    only_known_keys
      ~context
      [ "name"; "title"; "description"; "arguments" ]
      pairs
  in
  Ok
    { prompt_name = name
    ; prompt_title = title
    ; prompt_description = description
    ; prompt_arguments = arguments
    }
;;

let load_prompts ~contents =
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error (sprintf "mcp/prompts.toml: TOML parse error: %s" message)
  | Ok (Otoml.TomlTable pairs) ->
    (match List.assoc_opt "prompts" pairs with
     | None -> Error "mcp/prompts.toml: missing the required [[prompts]] array"
     | Some value ->
       (match
          entries_of_value ~context:"prompts" ~element:prompt_of_pairs value
        with
        | Ok prompts ->
          (match only_known_keys ~context:"prompts.toml" [ "prompts" ] pairs with
           | Ok () -> Ok prompts
           | Error message -> Error (sprintf "mcp/prompts.toml: %s" message))
        | Error message -> Error (sprintf "mcp/prompts.toml: %s" message)))
  | Ok
      ( ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
        | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
        | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
        | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
        | Otoml.TomlTableArray _ ) as other ) ->
    Error (sprintf "mcp/prompts.toml: top level must be a table, got %s" (toml_shape other))
;;

(* ── Embedded decode at module init ───────────────────────────────────── *)

let embedded_or_fail rel =
  match Embedded_config.read rel with
  | None -> failwith (sprintf "embedded mcp surface file missing: %s" rel)
  | Some contents -> contents
;;

let surface =
  match load_resources ~contents:(embedded_or_fail "mcp/resources.toml") with
  | Ok surface -> surface
  | Error message -> failwith message
;;

let prompts =
  match load_prompts ~contents:(embedded_or_fail "mcp/prompts.toml") with
  | Ok prompts -> prompts
  | Error message -> failwith message
;;

let server_description = surface.server_description
let tool_help_name_suffix = surface.tool_help_name_suffix
let resources = surface.resources
let resource_templates = surface.resource_templates

(* ── Embedded tree validation ─────────────────────────────────────────── *)

let mcp_asset_prefix = "mcp/"
let resources_relative_path = mcp_asset_prefix ^ "resources.toml"
let prompts_relative_path = mcp_asset_prefix ^ "prompts.toml"
let manifest_relative_path = mcp_asset_prefix ^ "managed-assets.json"

let validate_embedded ~read ~files =
  let validate_one acc rel =
    let* () = acc in
    if not (String.starts_with ~prefix:mcp_asset_prefix rel)
    then Ok ()
    else if String.equal rel manifest_relative_path
    then Ok ()
    else if not (String.equal (Filename.dirname rel) "mcp")
    then Error (sprintf "mcp surface files must sit directly under mcp/: %s" rel)
    else if String.equal rel resources_relative_path
    then (
      match read rel with
      | None -> Error (sprintf "embedded mcp surface file unreadable: %s" rel)
      | Some contents ->
        (match load_resources ~contents with
         | Ok (_ : surface) -> Ok ()
         | Error message -> Error message))
    else if String.equal rel prompts_relative_path
    then (
      match read rel with
      | None -> Error (sprintf "embedded mcp surface file unreadable: %s" rel)
      | Some contents ->
        (match load_prompts ~contents with
         | Ok (_ : prompt_entry list) -> Ok ()
         | Error message -> Error message))
    else Error (sprintf "unexpected file in the embedded mcp surface tree: %s" rel)
  in
  List.fold_left validate_one (Ok ()) files
;;
