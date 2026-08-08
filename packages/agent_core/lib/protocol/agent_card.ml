(** Agent Card — self-describing metadata for agent capability negotiation.

    Inspired by A2A (Agent-to-Agent) protocol.  An agent card declares
    what an agent can do: its tools, skills, supported providers, and
    high-level capabilities.  Useful for multi-agent orchestration where
    agents need to discover each other's abilities.

    No dependency on {!Agent} — receives data via {!agent_info} record.
    Compiled before Agent so Agent.card can call [of_info]. *)

(* ── Capability ─────────────────────────────────────────── *)

type capability =
  | Tools
  | Streaming
  | Thinking
  | StructuredOutput
  | Handoff
  | Checkpoint
  | MCP
  | Elicitation
  | Custom_cap of string
[@@deriving yojson, show]

(* ── Agent Card ─────────────────────────────────────────── *)

type credential_ref =
  | Env of string
  | File of string
  | No_credential

type authentication =
  { schemes : string list
  ; credential_ref : credential_ref
  }

type supported_interface =
  { url : string
  ; protocol_binding : string
  ; protocol_version : string
  ; tenant : string option
  }

type supported_interfaces =
  | Supported_interfaces of supported_interface * supported_interface list

type skill_meta =
  { name : string
  ; description : string option
  }
[@@deriving show]

type agent_card =
  { name : string
  ; description : string option
  ; version : string (** Agent implementation version *)
  ; authentication : authentication option
  ; supported_interfaces : supported_interfaces
  ; capabilities : capability list
  ; tools : Types.tool_schema list
  ; skills : skill_meta list
  ; supported_providers : string list
  ; metadata : (string * Yojson.Safe.t) list
  }

let invalid_config ~field ~detail =
  Error (Error.Config (Error.InvalidConfig { field; detail }))
;;

let validate_non_empty ~field value =
  if String.equal value ""
  then invalid_config ~field ~detail:"must not be empty"
  else if not (String.equal value (String.trim value))
  then invalid_config ~field ~detail:"must not contain surrounding whitespace"
  else Ok value
;;

let validate_object_fields ~path ~known fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      let field = path ^ "." ^ name in
      if List.mem name seen
      then invalid_config ~field ~detail:"must not be duplicated"
      else if not (List.mem name known)
      then invalid_config ~field ~detail:"is not supported"
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let create_supported_interface_at ~path ~url ~protocol_binding ~protocol_version ~tenant =
  let ( let* ) = Result.bind in
  let* url = validate_non_empty ~field:(path ^ ".url") url in
  let uri = Uri.of_string url in
  let* () =
    match Uri.Absolute_http.of_uri uri with
    | Ok absolute_uri
      when Uri.Absolute_http.scheme absolute_uri = `Https
           && not (String.equal (Uri.Absolute_http.host absolute_uri) "") -> Ok ()
    | _ ->
      invalid_config
        ~field:(path ^ ".url")
        ~detail:"must be an absolute HTTPS URL with a non-empty host"
  in
  let* protocol_binding =
    validate_non_empty ~field:(path ^ ".protocolBinding") protocol_binding
  in
  let* protocol_version =
    validate_non_empty ~field:(path ^ ".protocolVersion") protocol_version
  in
  let* tenant =
    match tenant with
    | None -> Ok None
    | Some value ->
      let* value = validate_non_empty ~field:(path ^ ".tenant") value in
      Ok (Some value)
  in
  Ok { url; protocol_binding; protocol_version; tenant }
;;

let create_supported_interface ~url ~protocol_binding ~protocol_version ?tenant () =
  create_supported_interface_at
    ~path:"supported_interface"
    ~url
    ~protocol_binding
    ~protocol_version
    ~tenant
;;

let supported_interfaces first rest = Supported_interfaces (first, rest)
let supported_interfaces_to_list (Supported_interfaces (first, rest)) = first :: rest

let supported_interfaces_of_list_at ~field = function
  | [] -> invalid_config ~field ~detail:"must contain at least one interface"
  | first :: rest -> Ok (supported_interfaces first rest)
;;

let supported_interfaces_of_list interfaces =
  supported_interfaces_of_list_at ~field:"supported_interfaces" interfaces
;;

(* ── Manual JSON serialization ─────────────────────────── *)

let capability_to_string = function
  | Tools -> "tools"
  | Streaming -> "streaming"
  | Thinking -> "thinking"
  | StructuredOutput -> "structured_output"
  | Handoff -> "handoff"
  | Checkpoint -> "checkpoint"
  | MCP -> "mcp"
  | Elicitation -> "elicitation"
  | Custom_cap s -> s
;;

let capability_of_string = function
  | "tools" -> Tools
  | "streaming" -> Streaming
  | "thinking" -> Thinking
  | "structured_output" -> StructuredOutput
  | "handoff" -> Handoff
  | "checkpoint" -> Checkpoint
  | "mcp" -> MCP
  | "elicitation" -> Elicitation
  | s -> Custom_cap s
;;

let to_json (card : agent_card) : Yojson.Safe.t =
  let opt key = function
    | Some v -> [ key, `String v ]
    | None -> []
  in
  let opt_auth =
    match card.authentication with
    | None -> []
    | Some a ->
      let credential_json =
        match a.credential_ref with
        | Env name -> `Assoc [ "type", `String "env"; "name", `String name ]
        | File path -> `Assoc [ "type", `String "file"; "path", `String path ]
        | No_credential -> `Null
      in
      [ ( "authentication"
        , `Assoc
            ([ "schemes", Util.json_of_string_list a.schemes ]
             @
             match a.credential_ref with
             | No_credential -> []
             | _ -> [ "credential_ref", credential_json ]) )
      ]
  in
  let interfaces_json =
    ( "supportedInterfaces"
    , `List
        (List.map
           (fun (si : supported_interface) ->
              `Assoc
                ([ "url", `String si.url
                 ; "protocolBinding", `String si.protocol_binding
                 ; "protocolVersion", `String si.protocol_version
                 ]
                 @
                 match si.tenant with
                 | Some tenant -> [ "tenant", `String tenant ]
                 | None -> []))
           (supported_interfaces_to_list card.supported_interfaces)) )
  in
  `Assoc
    ([ "name", `String card.name ]
     @ opt "description" card.description
     @ opt_auth
     @ [ interfaces_json ]
     @ [ "version", `String card.version
       ; ( "capabilities"
         , `List (List.map (fun c -> `String (capability_to_string c)) card.capabilities)
         )
       ; "tools", `List (List.map Types.tool_schema_to_yojson card.tools)
       ; ( "skills"
         , `List
             (List.map
                (fun (s : skill_meta) ->
                   `Assoc
                     ([ "name", `String s.name ]
                      @
                      match s.description with
                      | Some d -> [ "description", `String d ]
                      | None -> []))
                card.skills) )
       ; "supported_providers", Util.json_of_string_list card.supported_providers
       ]
     @
     match card.metadata with
     | [] -> []
     | m -> [ "metadata", `Assoc m ])
;;

let required_field fields ?key field =
  let key = Option.value key ~default:field in
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> invalid_config ~field ~detail:"is required"
;;

let required_string fields ?key field =
  let ( let* ) = Result.bind in
  let* value = required_field fields ?key field in
  match value with
  | `String value -> validate_non_empty ~field value
  | _ -> invalid_config ~field ~detail:"must be a string"
;;

let optional_string fields ?key field =
  let key = Option.value key ~default:field in
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> invalid_config ~field ~detail:"must be a string or null"
;;

let required_list fields ?key field =
  let ( let* ) = Result.bind in
  let* value = required_field fields ?key field in
  match value with
  | `List values -> Ok values
  | _ -> invalid_config ~field ~detail:"must be an array"
;;

let rec map_indexed_result index f = function
  | [] -> Ok []
  | value :: rest ->
    let ( let* ) = Result.bind in
    let* value = f index value in
    let* rest = map_indexed_result (index + 1) f rest in
    Ok (value :: rest)
;;

let strings_of_json ~field values =
  map_indexed_result
    0
    (fun index -> function
       | `String value ->
         validate_non_empty ~field:(Printf.sprintf "%s[%d]" field index) value
       | _ ->
         invalid_config
           ~field:(Printf.sprintf "%s[%d]" field index)
           ~detail:"must be a string")
    values
;;

let supported_interface_of_json index = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let path = Printf.sprintf "supportedInterfaces[%d]" index in
    let* () =
      validate_object_fields
        ~path
        ~known:[ "url"; "protocolBinding"; "protocolVersion"; "tenant" ]
        fields
    in
    let* url = required_string fields ~key:"url" (path ^ ".url") in
    let* protocol_binding =
      required_string fields ~key:"protocolBinding" (path ^ ".protocolBinding")
    in
    let* protocol_version =
      required_string fields ~key:"protocolVersion" (path ^ ".protocolVersion")
    in
    let* tenant = optional_string fields ~key:"tenant" (path ^ ".tenant") in
    create_supported_interface_at ~path ~url ~protocol_binding ~protocol_version ~tenant
  | _ ->
    invalid_config
      ~field:(Printf.sprintf "supportedInterfaces[%d]" index)
      ~detail:"must be an object"
;;

let credential_ref_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      validate_object_fields
        ~path:"authentication.credential_ref"
        ~known:[ "type"; "name"; "path" ]
        fields
    in
    let* kind = required_string fields ~key:"type" "authentication.credential_ref.type" in
    (match kind with
     | "env" ->
       let* () =
         validate_object_fields
           ~path:"authentication.credential_ref"
           ~known:[ "type"; "name" ]
           fields
       in
       let* name =
         required_string fields ~key:"name" "authentication.credential_ref.name"
       in
       Ok (Env name)
     | "file" ->
       let* () =
         validate_object_fields
           ~path:"authentication.credential_ref"
           ~known:[ "type"; "path" ]
           fields
       in
       let* path =
         required_string fields ~key:"path" "authentication.credential_ref.path"
       in
       Ok (File path)
     | value ->
       invalid_config
         ~field:"authentication.credential_ref.type"
         ~detail:(Printf.sprintf "unsupported value %S" value))
  | _ -> invalid_config ~field:"authentication.credential_ref" ~detail:"must be an object"
;;

let authentication_of_json fields =
  match List.assoc_opt "authentication" fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc auth_fields) ->
    let ( let* ) = Result.bind in
    let* () =
      validate_object_fields
        ~path:"authentication"
        ~known:[ "schemes"; "credential_ref"; "credentials" ]
        auth_fields
    in
    let* () =
      match List.assoc_opt "credentials" auth_fields with
      | None -> Ok ()
      | Some _ ->
        invalid_config
          ~field:"authentication.credentials"
          ~detail:"literal credentials are forbidden; use credential_ref"
    in
    let* schemes_json =
      required_list auth_fields ~key:"schemes" "authentication.schemes"
    in
    let* schemes = strings_of_json ~field:"authentication.schemes" schemes_json in
    let* () =
      match schemes with
      | [] ->
        invalid_config
          ~field:"authentication.schemes"
          ~detail:"must contain at least one scheme"
      | _ -> Ok ()
    in
    let* credential_ref =
      match List.assoc_opt "credential_ref" auth_fields with
      | None | Some `Null -> Ok No_credential
      | Some value -> credential_ref_of_json value
    in
    Ok (Some { schemes; credential_ref })
  | Some _ -> invalid_config ~field:"authentication" ~detail:"must be an object or null"
;;

let skill_of_json index = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let path = Printf.sprintf "skills[%d]" index in
    let* () = validate_object_fields ~path ~known:[ "name"; "description" ] fields in
    let* name = required_string fields ~key:"name" (path ^ ".name") in
    let* description =
      optional_string fields ~key:"description" (path ^ ".description")
    in
    Ok { name; description }
  | _ ->
    invalid_config ~field:(Printf.sprintf "skills[%d]" index) ~detail:"must be an object"
;;

let tool_schema_of_json index json =
  match Types.tool_schema_of_yojson json with
  | Ok tool -> Ok tool
  | Error detail -> invalid_config ~field:(Printf.sprintf "tools[%d]" index) ~detail
;;

let of_json (json : Yojson.Safe.t) : (agent_card, Error.sdk_error) result =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      validate_object_fields
        ~path:"agent_card"
        ~known:
          [ "name"
          ; "description"
          ; "version"
          ; "authentication"
          ; "supportedInterfaces"
          ; "capabilities"
          ; "tools"
          ; "skills"
          ; "supported_providers"
          ; "metadata"
          ]
        fields
    in
    let* name = required_string fields "name" in
    let* description = optional_string fields "description" in
    let* version = required_string fields "version" in
    let* interface_values = required_list fields "supportedInterfaces" in
    let* interfaces = map_indexed_result 0 supported_interface_of_json interface_values in
    let* supported_interfaces =
      supported_interfaces_of_list_at ~field:"supportedInterfaces" interfaces
    in
    let* capability_values = required_list fields "capabilities" in
    let* capability_names = strings_of_json ~field:"capabilities" capability_values in
    let capabilities = List.map capability_of_string capability_names in
    let* tool_values = required_list fields "tools" in
    let* tools = map_indexed_result 0 tool_schema_of_json tool_values in
    let* skill_values = required_list fields "skills" in
    let* skills = map_indexed_result 0 skill_of_json skill_values in
    let* provider_values = required_list fields "supported_providers" in
    let* supported_providers =
      strings_of_json ~field:"supported_providers" provider_values
    in
    let* metadata =
      match List.assoc_opt "metadata" fields with
      | None | Some `Null -> Ok []
      | Some (`Assoc pairs) ->
        let* () =
          validate_object_fields
            ~path:"metadata"
            ~known:(List.map fst pairs |> List.sort_uniq String.compare)
            pairs
        in
        Ok pairs
      | Some _ -> invalid_config ~field:"metadata" ~detail:"must be an object or null"
    in
    let* authentication = authentication_of_json fields in
    Ok
      { name
      ; description
      ; version
      ; authentication
      ; supported_interfaces
      ; capabilities
      ; tools
      ; skills
      ; supported_providers
      ; metadata
      }
  | _ -> invalid_config ~field:"agent_card" ~detail:"must be an object"
;;

(* ── Construct from agent_info (decoupled from Agent.t) ── *)

type agent_info =
  { agent_name : string
  ; agent_description : string option
  ; version : string
  ; config : Types.agent_config
  ; tool_schemas : Types.tool_schema list
  ; supported_providers : string list
  ; mcp_clients_count : int
  ; has_elicitation : bool
  ; skills : skill_meta list
  ; supported_interfaces : supported_interfaces
  }

let of_info (info : agent_info) : agent_card =
  let optional_capability condition capability =
    if condition then [ capability ] else []
  in
  let capabilities =
    optional_capability (info.tool_schemas <> []) Tools
    @ [ Streaming ]
    @ (match info.config.enable_thinking with
       | Some true -> [ Thinking ]
       | Some false | None -> [])
    @ optional_capability (info.mcp_clients_count > 0) MCP
    @ optional_capability info.has_elicitation Elicitation
  in
  let all_providers = List.sort_uniq String.compare info.supported_providers in
  { name = info.agent_name
  ; description = info.agent_description
  ; version = info.version
  ; authentication = None
  ; supported_interfaces = info.supported_interfaces
  ; capabilities
  ; tools = info.tool_schemas
  ; skills = info.skills
  ; supported_providers = all_providers
  ; metadata = []
  }
;;

(* ── Queries ───────────────────────────────────────────── *)

let has_capability (card : agent_card) cap =
  List.exists (fun c -> c = cap) card.capabilities
;;

let can_handle_tool (card : agent_card) tool_name =
  List.exists (fun (t : Types.tool_schema) -> t.name = tool_name) card.tools
;;

let has_skill (card : agent_card) skill_name =
  List.exists (fun (s : skill_meta) -> s.name = skill_name) card.skills
;;
