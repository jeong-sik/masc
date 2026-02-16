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
  url: string option;
} [@@deriving yojson, show, eq]

(** Skill definition for agent capabilities *)
type skill = {
  id: string;
  name: string;
  description: string option;
  input_modes: string list;   (** MIME types: "text/plain", "application/json" *)
  output_modes: string list;  (** MIME types: "text/plain", "application/json" *)
} [@@deriving yojson, show, eq]

(** Protocol binding for agent communication.
    Internal type; serialized as "supportedInterfaces" in v0.3 JSON. *)
type binding = {
  protocol: string;  (** "JSONRPC" | "GRPC" | "REST" | "SSE" *)
  url: string;
} [@@deriving yojson, show, eq]

(** Security scheme for authentication *)
type security_scheme = {
  scheme_type: string;  (** "bearer" | "apiKey" | "oauth2" | "openIdConnect" | "mutualTLS" | "none" *)
  bearer_format: string option;
  api_key_name: string option;
  api_key_in: string option;  (** "header" | "query" *)
} [@@deriving yojson, show, eq]

(** Structured capabilities — A2A v0.3 spec *)
type agent_capabilities = {
  streaming: bool;
  push_notifications: bool;
  extended_agent_card: bool;
} [@@deriving yojson, show, eq]

(** JWS signature for Agent Card signing — A2A v0.3 spec (RFC 7515) *)
type agent_card_signature = {
  protected_header: string;  (** Base64url-encoded JSON (alg, kid) *)
  signature: string;         (** Base64url-encoded computed signature *)
  header: (string * string) list;  (** Optional unprotected JWS header *)
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

let capabilities_to_json (c : agent_capabilities) : Yojson.Safe.t =
  `Assoc [
    ("streaming", `Bool c.streaming);
    ("pushNotifications", `Bool c.push_notifications);
    ("extendedAgentCard", `Bool c.extended_agent_card);
  ]

let capabilities_of_json (json : Yojson.Safe.t) : agent_capabilities =
  let module U = Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
    {
      streaming = (try json |> U.member "streaming" |> U.to_bool with _ -> false);
      push_notifications = (try json |> U.member "pushNotifications" |> U.to_bool with _ -> false);
      extended_agent_card = (try json |> U.member "extendedAgentCard" |> U.to_bool with _ -> false);
    }
  | `List strs ->
    (* Backward compat: parse old string list format *)
    let has s = List.exists (fun v -> try U.to_string v = s with _ -> false) strs in
    {
      streaming = has "streaming";
      push_notifications = has "push-notifications";
      extended_agent_card = false;
    }
  | _ ->
    { streaming = false; push_notifications = false; extended_agent_card = false }

let signature_to_json (s : agent_card_signature) : Yojson.Safe.t =
  `Assoc ([
    ("protected", `String s.protected_header);
    ("signature", `String s.signature);
  ] @ (if s.header = [] then [] else [
    ("header", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.header))
  ]))

let signature_of_json (json : Yojson.Safe.t) : agent_card_signature option =
  let module U = Yojson.Safe.Util in
  try
    let protected_header = json |> U.member "protected" |> U.to_string in
    let signature = json |> U.member "signature" |> U.to_string in
    let header =
      match json |> U.member "header" with
      | `Assoc pairs -> List.filter_map (fun (k, v) ->
          try Some (k, U.to_string v) with _ -> None) pairs
      | _ -> []
    in
    Some { protected_header; signature; header }
  with _ -> None

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
  let module U = Yojson.Safe.Util in
  try
    let name = json |> U.member "name" |> U.to_string in
    let version = json |> U.member "version" |> U.to_string in
    let description = json |> U.member "description" |> U.to_string_option in

    let provider =
      match json |> U.member "provider" with
      | `Null -> None
      | p ->
        match provider_of_yojson p with
        | Ok v -> Some v
        | Error _ -> None
    in

    let protocol_versions =
      match json |> U.member "protocolVersions" with
      | `List vs -> List.filter_map (fun v -> try Some (U.to_string v) with _ -> None) vs
      | _ -> ["0.3"]
    in

    let capabilities = capabilities_of_json (json |> U.member "capabilities") in

    let skills =
      (match json |> U.member "skills" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun s ->
        match skill_of_yojson s with
        | Ok v -> Some v
        | Error _ -> None)
    in

    (* Accept both "supportedInterfaces" (v0.3) and "bindings" (legacy) *)
    let supported_interfaces =
      let ifaces_json =
        match json |> U.member "supportedInterfaces" with
        | `List _ as v -> v
        | _ -> json |> U.member "bindings"
      in
      (match ifaces_json with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun b ->
        match binding_of_yojson b with
        | Ok v -> Some v
        | Error _ -> None)
    in

    let security_schemes =
      match json |> U.member "securitySchemes" with
      | `Assoc pairs ->
        List.filter_map (fun (k, v) ->
          match security_scheme_of_yojson v with
          | Ok scheme -> Some (k, scheme)
          | Error _ -> None) pairs
      | _ -> []
    in

    let default_input_modes =
      (match json |> U.member "defaultInputModes" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun v -> try Some (U.to_string v) with _ -> None)
    in

    let default_output_modes =
      (match json |> U.member "defaultOutputModes" with
      | `List vs -> vs | _ -> [])
      |> List.filter_map (fun v -> try Some (U.to_string v) with _ -> None)
    in

    let extensions =
      match json |> U.member "extensions" with
      | `Assoc pairs -> pairs
      | _ -> []
    in

    (* Accept both "signatures" (v0.3 array) and "signature" (legacy string) *)
    let signatures =
      match json |> U.member "signatures" with
      | `List vs -> List.filter_map signature_of_json vs
      | _ ->
        match json |> U.member "signature" |> U.to_string_option with
        | Some s -> [{ protected_header = ""; signature = s; header = [] }]
        | None -> []
    in

    let icon_url = json |> U.member "iconUrl" |> U.to_string_option in
    let documentation_url = json |> U.member "documentationUrl" |> U.to_string_option in
    let created_at = json |> U.member "createdAt" |> U.to_string in
    let updated_at = json |> U.member "updatedAt" |> U.to_string in

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

(** MASC skill definitions (MIME-typed for v0.3) *)
let masc_skills : skill list = [
  {
    id = "task-management";
    name = "Task Management";
    description = Some "Create, claim, and complete tasks on the quest board";
    input_modes = ["text/plain"; "application/json"];
    output_modes = ["text/plain"; "application/json"];
  };
  {
    id = "agent-coordination";
    name = "Agent Coordination";
    description = Some "Join room, broadcast messages, coordinate with other agents";
    input_modes = ["text/plain"];
    output_modes = ["text/plain"; "text/event-stream"];
  };
  {
    id = "file-locking";
    name = "File Locking";
    description = Some "Lock and unlock files to prevent concurrent edits";
    input_modes = ["text/plain"];
    output_modes = ["text/plain"];
  };
  {
    id = "git-worktree";
    name = "Git Worktree Management";
    description = Some "Create isolated git worktrees for parallel development";
    input_modes = ["text/plain"];
    output_modes = ["text/plain"; "application/octet-stream"];
  };
  {
    id = "voting";
    name = "Multi-Agent Voting";
    description = Some "Create votes and reach consensus among agents";
    input_modes = ["text/plain"; "application/json"];
    output_modes = ["text/plain"; "application/json"];
  };
  {
    id = "cost-tracking";
    name = "Cost Tracking";
    description = Some "Log and report token usage and API costs";
    input_modes = ["application/json"];
    output_modes = ["text/plain"; "application/json"];
  };
  {
    id = "human-in-loop";
    name = "Human-in-the-Loop";
    description = Some "Interrupt workflows for user approval on sensitive actions";
    input_modes = ["text/plain"];
    output_modes = ["text/plain"];
  };
  {
    id = "portal-a2a";
    name = "A2A Portal Communication";
    description = Some "Direct agent-to-agent private communication channels";
    input_modes = ["text/plain"; "application/json"];
    output_modes = ["text/plain"; "text/event-stream"];
  };
]

(** Generate default MASC agent card (A2A v0.3 compliant) *)
let generate_default ?(port=8935) ?(host="127.0.0.1") () : agent_card =
  let timestamp = now_iso8601 () in
  let base_url = Printf.sprintf "http://%s:%d" host port in
  {
    name = "MASC-MCP";
    version = "2.60.0";
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
    skills = masc_skills;
    supported_interfaces = [
      { protocol = "SSE"; url = Printf.sprintf "%s/sse" base_url };
      { protocol = "JSONRPC"; url = Printf.sprintf "%s/mcp" base_url };
      { protocol = "REST"; url = Printf.sprintf "%s/api/v1" base_url };
      { protocol = "GRPC"; url = Printf.sprintf "grpc://%s:%d" host (port + 1000) };
    ];
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
        ("roomPath", `String ".masc");
        ("storageTypes", `List [`String "file"; `String "postgres"]);
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
