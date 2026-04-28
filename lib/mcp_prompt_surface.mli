(** Mcp_prompt_surface — canonical MCP `prompts/list` + `prompts/get`
    catalogue.

    Defines the small set of MCP "prompt definitions" the MASC server
    advertises (currently a single [tool_help] prompt) and the
    rendering logic that turns a {!prompt_def} + caller-supplied
    arguments into the JSON-RPC message body.

    The surface is intentionally narrow: callers see the typed
    catalogue ({!prompt_defs}), the per-prompt JSON projection
    ({!prompt_json}), and the {!get_json} entry point that the
    JSON-RPC dispatcher invokes for [prompts/get].  All internal
    helpers ([lookup], [assoc_string], [message_json], [tool_help_text],
    [list_json]) stay private — they are stable contract-internal
    pieces but exposing them would invite duplicate-rendering paths
    that drift from the canonical {!get_json}. *)

(** {1 Prompt argument schema} *)

type prompt_argument = {
  name : string;
  description : string;
  required : bool;
}
(** Concrete record because both consumers
    ({!Mcp_sdk_adapter_masc} and {!Mcp_server_eio_protocol}) destructure
    it field-by-field when projecting to the SDK / wire JSON shape.
    Hiding would break those at the type seam. *)

(** {1 Prompt definition} *)

type prompt_def = {
  name : string;
  title : string;
  description : string;
  arguments : prompt_argument list;
  icons : Mcp_server.mcp_icon list;
}
(** Concrete record for the same reason as {!prompt_argument} —
    {!Mcp_sdk_adapter_masc.sdk_prompt_of_local} reads every field.

    The [icons] field is non-optional and currently always populated
    with a single themed icon; the contract permits an empty list,
    but UI clients have a degraded fallback that operators dislike
    so the catalogue convention is "always provide at least one icon". *)

val prompt_defs : prompt_def list
(** The canonical, ordered prompt catalogue.  Currently contains a
    single entry, [tool_help] (compose a grounded explanation for a
    specific MASC MCP tool).  Adding a new prompt requires:
    1. extending this list,
    2. extending the [match] in {!get_json} with a new arm,
    3. updating the operator runbook for the new prompt name.

    The list is the SSOT — both {!Mcp_sdk_adapter_masc} and
    {!Mcp_server_eio_protocol} consume it to build their respective
    paginated [prompts/list] responses (sorted by name, paginated
    independently per transport). *)

val prompt_json : prompt_def -> Yojson.Safe.t
(** [prompt_json def] returns the canonical JSON object for one
    prompt definition with fields [name] / [title] / [description] /
    [icons] / [arguments].  Each argument renders with the same
    field set ([name] / [description] / [required]) so the wire
    contract is uniform across prompts. *)

val get_json :
  config:Coord.config ->
  name:string ->
  arguments:Yojson.Safe.t ->
  Types.tool_schema list ->
  (Yojson.Safe.t, string) result
(** [get_json ~config ~name ~arguments schemas] is the JSON-RPC
    [prompts/get] entry point.

    On success, returns
    {[
      `Assoc [
        ("description", `String prompt.description);
        ("messages", `List [ <one user message> ]);
      ]
    ]}
    where the message has role ["user"] and content
    [`Assoc [("type", `String "text"); ("text", `String <body>)]].

    Error wording is operator-visible (returned through the JSON-RPC
    error envelope by the caller):
    - [unknown prompt: <name>] — [name] is not in {!prompt_defs}.
    - [unknown tool: <tool_name>] — [tool_name] is not in [schemas]
      (only reachable through the [tool_help] prompt).
    - [tool_name is required] — [arguments] is missing the
      [tool_name] string.
    - [unsupported prompt: <name>] — [name] resolved to a
      {!prompt_def} but {!get_json} has no rendering arm for it (this
      is a developer error — every prompt in {!prompt_defs} must have
      a matching [match] arm here).

    The [config] parameter is currently unused but kept in the
    signature so a future prompt that needs room/agent context can
    consume it without changing the contract. *)
