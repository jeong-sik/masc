(** Agent Card - A2A Protocol v0.3.0 Compatible Agent Metadata

    Implements the A2A Agent Card specification for standardized agent discovery.
    Provides `/.well-known/agent-card.json` endpoint support.

    v0.3.0 changes:
    - capabilities: structured record (streaming, pushNotifications, extendedAgentCard)
    - supportedInterfaces replaces bindings (protocol enum)
    - signatures: JWS array (RFC 7515) replaces single signature string
    - protocolVersions field
    - MIME types for input/output modes
    - iconUrl, documentationUrl optional fields

    @see https://a2a-protocol.org/latest/specification/
    @since 2.60.0 *)

(** Provider information for the agent *)
type provider = {
  organization: string;
  url: string option [@default None];
} [@@deriving yojson, show, eq]

(** Skill definition for agent capabilities.
    A2A v0.3 compatible with [tags] for category-based discovery.
    [tool_count] tracks how many MCP tools this skill aggregates. *)
type skill = {
  id: string;
  name: string;
  description: string option [@default None];
  tags: string list [@default []];           (** Category tags for skill discovery *)
  input_modes: string list;    (** MIME types: "text/plain", "application/json" *)
  output_modes: string list;   (** MIME types: "text/plain", "application/json" *)
  tool_count: int [@default 0];             (** Number of MCP tools under this skill *)
} [@@deriving yojson, show, eq]

(** Protocol binding for agent communication.
    Internal type; serialized as "supportedInterfaces" in v0.3 JSON. *)
type binding = {
  protocol: string;  (** "JSONRPC" | "GRPC" | "REST" | "SSE" | "WEBSOCKET" | "WEBRTC" *)
  url: string;
} [@@deriving yojson, show, eq]

(** Security scheme for authentication *)
type security_scheme = {
  scheme_type: string;  (** "bearer" | "apiKey" | "oauth2" | "openIdConnect" | "mutualTLS" | "none" *)
  bearer_format: string option [@default None];
  api_key_name: string option [@default None];
  api_key_in: string option [@default None];  (** "header" | "query" *)
} [@@deriving yojson, show, eq]

(** Structured capabilities — A2A v0.3 spec *)
type agent_capabilities = {
  streaming: bool;
  push_notifications: bool [@key "pushNotifications"];
  extended_agent_card: bool [@key "extendedAgentCard"];
} [@@deriving yojson, show, eq]

(** String-keyed object serialized as JSON {"k":"v",...} instead of [["k","v"],...] *)
type string_assoc = (string * string) list [@@deriving show, eq]
let string_assoc_to_yojson (xs : string_assoc) : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) xs)
let string_assoc_of_yojson (json : Yojson.Safe.t) : (string_assoc, string) result =
  match json with
  | `Assoc pairs ->
    Ok (List.filter_map (fun (k, v) ->
      match v with `String s -> Some (k, s) | _ -> None) pairs)
  | `Null -> Ok []
  | _ -> Error "expected object for string_assoc"

(** JWS signature for Agent Card signing — A2A v0.3 spec (RFC 7515) *)
type agent_card_signature = {
  protected_header: string [@key "protected"];  (** Base64url-encoded JSON (alg, kid) *)
  signature: string;         (** Base64url-encoded computed signature *)
  header: string_assoc [@default []];  (** Optional unprotected JWS header *)
} [@@deriving yojson, show, eq]

(** Agent Card - A2A v0.3.0 compliant agent metadata *)
type agent_card = {
  name: string;
  version: string;
  description: string option;
  provider: provider option;
  protocol_versions: string list;          (** e.g., ["0.3"] *)
  capabilities: agent_capabilities;        (** Structured capabilities *)
  skills: skill list;
  supported_interfaces: binding list;      (** v0.3: supportedInterfaces *)
  security_schemes: (string * security_scheme) list;
  default_input_modes: string list;        (** MIME types *)
  default_output_modes: string list;       (** MIME types *)
  extensions: (string * Yojson.Safe.t) list;
  signatures: agent_card_signature list;   (** v0.3: JWS signatures *)
  icon_url: string option;                 (** v0.3: agent icon *)
  documentation_url: string option;        (** v0.3: documentation link *)
  created_at: string;
  updated_at: string;
} [@@deriving show, eq]

(* ---------- JSON Serialization ---------- *)

(* Derived [agent_capabilities_to_yojson] produces correct camelCase via [@key]. *)
let capabilities_to_json = agent_capabilities_to_yojson

let capabilities_of_json (json : Yojson.Safe.t) : agent_capabilities =
  match json with
  | `Assoc _ ->
    (match agent_capabilities_of_yojson json with
     | Ok c -> c
     | Error msg ->
       Log.Misc.warn "[agent_card] capabilities_of_json parse error: %s" msg;
       { streaming = false; push_notifications = false; extended_agent_card = false })
  | `List strs ->
    (* Backward compat: parse old string list format *)
    let has s = List.exists (fun v ->
      match v with `String x -> String.equal x s | _ -> false) strs in
    {
      streaming = has "streaming";
      push_notifications = has "push-notifications";
      extended_agent_card = false;
    }
  | _ ->
    { streaming = false; push_notifications = false; extended_agent_card = false }

(* Derived [agent_card_signature_to_yojson] produces correct keys via [@key]. *)
let signature_to_json = agent_card_signature_to_yojson

let signature_of_json (json : Yojson.Safe.t) : agent_card_signature option =
  match agent_card_signature_of_yojson json with
  | Ok s -> Some s
  | Error msg ->
    Log.Misc.warn "[agent_card] signature_of_json parse error: %s" msg;
    None

(** Convert agent_card to JSON (A2A v0.3 spec format) *)
let to_json (card : agent_card) : Yojson.Safe.t =
  let optional_string key = function
    | None -> []
    | Some v -> [(key, `String v)]
  in
  let optional_obj key = function
    | None -> []
    | Some v -> [(key, provider_to_yojson v)]
  in
  `Assoc ([
    ("name", `String card.name);
    ("version", `String card.version);
  ] @ optional_string "description" card.description
    @ optional_obj "provider" card.provider
    @ [
    ("protocolVersions", `List (List.map (fun s -> `String s) card.protocol_versions));
    ("capabilities", capabilities_to_json card.capabilities);
    ("skills", `List (List.map skill_to_yojson card.skills));
    ("supportedInterfaces", `List (List.map binding_to_yojson card.supported_interfaces));
    ("securitySchemes", `Assoc (List.map (fun (k, v) -> (k, security_scheme_to_yojson v)) card.security_schemes));
    ("defaultInputModes", `List (List.map (fun s -> `String s) card.default_input_modes));
    ("defaultOutputModes", `List (List.map (fun s -> `String s) card.default_output_modes));
  ] @ (if card.extensions = [] then [] else [
    ("extensions", `Assoc card.extensions)
  ]) @ (if card.signatures = [] then [] else [
    ("signatures", `List (List.map signature_to_json card.signatures))
  ]) @ optional_string "iconUrl" card.icon_url
    @ optional_string "documentationUrl" card.documentation_url
    @ [
    ("createdAt", `String card.created_at);
    ("updatedAt", `String card.updated_at);
  ])

(** Parse agent_card from JSON (accepts both v0.3 and legacy formats) *)
let from_json (json : Yojson.Safe.t) : (agent_card, string) result =
  let open Yojson.Safe.Util in
  try
    let name = json |> member "name" |> to_string in
    let version = json |> member "version" |> to_string in
    let description = json |> member "description" |> to_string_option in

    let provider =
      match json |> member "provider" with
      | `Null -> None
      | p ->
        match provider_of_yojson p with
        | Ok v -> Some v
        | Error msg ->
          Log.Misc.warn "[agent_card] provider parse error: %s" msg;
          None
    in

    let protocol_versions =
      match json |> member "protocolVersions" with
      | `List vs -> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None) vs
      | _ -> ["0.3"]
    in

    let capabilities = capabilities_of_json (json |> member "capabilities") in

    let skills =
      (match json |> member "skills" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun s ->
        match skill_of_yojson s with
        | Ok v -> Some v
        | Error msg ->
          Log.Misc.warn "[agent_card] skill parse error: %s" msg;
          None)
    in

    (* Accept both "supportedInterfaces" (v0.3) and "bindings" (legacy) *)
    let supported_interfaces =
      let ifaces_json =
        match json |> member "supportedInterfaces" with
        | `List _ as v -> v
        | _ -> json |> member "bindings"
      in
      (match ifaces_json with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun b ->
        match binding_of_yojson b with
        | Ok v -> Some v
        | Error msg ->
          Log.Misc.warn "[agent_card] binding parse error: %s" msg;
          None)
    in

    let security_schemes =
      match json |> member "securitySchemes" with
      | `Assoc pairs ->
        List.filter_map (fun (k, v) ->
          match security_scheme_of_yojson v with
          | Ok scheme -> Some (k, scheme)
          | Error msg ->
            Log.Misc.warn "[agent_card] security_scheme parse error for %s: %s" k msg;
            None) pairs
      | _ -> []
    in

    let default_input_modes =
      (match json |> member "defaultInputModes" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None)
    in

    let default_output_modes =
      (match json |> member "defaultOutputModes" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None)
    in

    let extensions =
      match json |> member "extensions" with
      | `Assoc pairs -> pairs
      | _ -> []
    in

    (* Accept both "signatures" (v0.3 array) and "signature" (legacy string) *)
    let signatures =
      match json |> member "signatures" with
      | `List vs -> List.filter_map signature_of_json vs
      | _ ->
        match json |> member "signature" |> to_string_option with
        | Some s -> [{ protected_header = ""; signature = s; header = [] }]
        | None -> []
    in

    let icon_url = json |> member "iconUrl" |> to_string_option in
    let documentation_url = json |> member "documentationUrl" |> to_string_option in
    let created_at = json |> member "createdAt" |> to_string in
    let updated_at = json |> member "updatedAt" |> to_string in

    Ok {
      name;
      version;
      description;
      provider;
      protocol_versions;
      capabilities;
      skills;
      supported_interfaces;
      security_schemes;
      default_input_modes;
      default_output_modes;
      extensions;
      signatures;
      icon_url;
      documentation_url;
      created_at;
      updated_at;
    }
  with
  | e -> Error (Printf.sprintf "Failed to parse agent card: %s" (Printexc.to_string e))

(** Get current ISO8601 timestamp *)
let now_iso8601 () : string =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** Build A2A skills dynamically from MCP tool schemas.

    Returns a single "masc" skill covering all tools. *)
let skills_from_tools (schemas : Types.tool_schema list) : skill list =
  let count = List.length schemas in
  if count = 0 then []
  else
    [{
      id = "masc";
      name = "MASC";
      description = Some "Multi-Agent Streaming Coordination tools";
      tags = ["masc"];
      input_modes = ["application/json"];
      output_modes = ["application/json"; "text/plain"];
      tool_count = count;
    }]

let runtime_supported_interfaces ~host ~port =
  let base_url = Printf.sprintf "http://%s:%d" host port in
  let bindings =
    [
      { protocol = "SSE"; url = Printf.sprintf "%s/sse" base_url };
      { protocol = "JSONRPC"; url = Printf.sprintf "%s/mcp" base_url };
      { protocol = "REST"; url = Printf.sprintf "%s/api/v1" base_url };
    ]
  in
  let bindings =
    if Masc_grpc_server.is_enabled () then
      bindings
      @ [
          {
            protocol = "GRPC";
            url =
              Printf.sprintf "grpc://%s:%d" host
                (Masc_grpc_server.configured_port ());
          };
        ]
    else
      bindings
  in
  let bindings =
    if Server_ws_standalone.is_enabled () then
      bindings
      @ [
          {
            protocol = "WEBSOCKET";
            url =
              Printf.sprintf "ws://%s:%d/" host
                (Server_ws_standalone.configured_port ());
          };
        ]
    else
      bindings
  in
  if Server_webrtc_transport.is_enabled () then
    bindings @ [ { protocol = "WEBRTC"; url = Printf.sprintf "%s/webrtc" base_url } ]
  else
    bindings

(** Generate default MASC agent card (A2A v0.3 compliant).
    [schemas] defaults to [Config.raw_all_tool_schemas] when provided,
    populating skills dynamically from actual MCP tools. *)
let generate_default
    ?(port = Env_config_core.masc_http_port_int ())
    ?(host = Env_config_core.masc_host ())
    ?(schemas=[]) () : agent_card =
  let timestamp = now_iso8601 () in
  let skills = match schemas with
    | [] -> []  (* Caller should pass schemas for dynamic skills *)
    | ss -> skills_from_tools ss
  in
  let supported_interfaces = runtime_supported_interfaces ~host ~port in
  {
    name = "MASC-MCP";
    version = Version.version;
    description = Some "Multi-Agent Streaming Coordination - A2A v0.3 compatible agent coordination system";
    provider = Some {
      organization = "Second Brain";
      url = Some "https://github.com/jeong-sik/me";
    };
    protocol_versions = ["0.3"];
    capabilities = {
      streaming = true;
      push_notifications = true;
      extended_agent_card = false;
    };
    skills;
    supported_interfaces;
    security_schemes = [
      ("bearer", {
        scheme_type = "bearer";
        bearer_format = Some "MASC Token";
        api_key_name = None;
        api_key_in = None;
      });
      ("none", {
        scheme_type = "none";
        bearer_format = None;
        api_key_name = None;
        api_key_in = None;
      });
    ];
    default_input_modes = ["text/plain"; "application/json"];
    default_output_modes = ["text/plain"; "application/json"; "text/event-stream"];
    extensions = [
      ("masc", `Assoc [
        ("roomPath", `String Common.masc_dirname);
        ("storageTypes", `List [`String "file"]);
        ("features", `Assoc [
          ("voting", `Bool true);
          ("worktree", `Bool true);
          ("costTracking", `Bool true);
          ("encryption", `Bool true);
          ("rateLimiting", `Bool true);
          ("zombieGC", `Bool true);
          ("branchExecution", `Bool true);
        ]);
      ]);
    ];
    signatures = [];
    icon_url = None;
    documentation_url = Some "https://github.com/jeong-sik/masc-mcp";
    created_at = timestamp;
    updated_at = timestamp;
  }

(** Update agent card with new interfaces based on runtime config *)
let with_interfaces (card : agent_card) (interfaces : binding list) : agent_card =
  let timestamp = now_iso8601 () in
  { card with supported_interfaces = interfaces; updated_at = timestamp }

(** Backward compat alias *)
let with_bindings = with_interfaces

(** Add extension data to agent card *)
let with_extension (card : agent_card) (key : string) (value : Yojson.Safe.t) : agent_card =
  let timestamp = now_iso8601 () in
  let extensions =
    List.filter (fun (k, _) -> k <> key) card.extensions
    @ [(key, value)]
  in
  { card with extensions; updated_at = timestamp }

(* ── Agent Card Cache ─────────────────────────────────────── *)

(** Cached agent card with generation counter for invalidation.
    The card is generated once on first access and reused until
    [invalidate_cache] is called (e.g. when tools change). *)
type cached_card = {
  card: agent_card;
  card_json: string;  (** Pre-serialized JSON for fast HTTP response *)
  generation: int;
}

let _cache : cached_card option ref = ref None
let _cache_generation : int ref = ref 0
(** Get cached agent card, generating if needed.
    [schemas] is used only on first generation or after invalidation.
    Returns [(card, json_string)] for direct HTTP response. *)
let get_cached
    ?(port = Env_config_core.masc_http_port_int ())
    ?(host = Env_config_core.masc_host ())
    ~schemas () : agent_card * string =
  let gen = !_cache_generation in
  match !_cache with
  | Some c when c.generation = gen -> (c.card, c.card_json)
  | _ ->
    let card = generate_default ~port ~host ~schemas () in
    let json_str = to_json card |> Yojson.Safe.to_string in
    _cache := Some { card; card_json = json_str; generation = gen };
    (card, json_str)

(** Invalidate the cached agent card. Call when tools are added/removed. *)
let invalidate_cache () =
  incr _cache_generation
