(** Runtime_official_client_tool — the dynamic-tool contract the official
    client runtimes share.

    A dynamic tool is one the keeper hands to a running provider session at
    turn time rather than one baked into the runtime. {!Runtime_claude_code}
    and {!Runtime_codex_app_server} both take a list of them, and
    {!Keeper_official_client_host} builds that list; all three declared the
    same record independently, so every hand-off between them needed a
    field-for-field copy to cross the nominal type boundary. The record lives
    here once and the three re-export it by type equation, which makes those
    copies unnecessary rather than merely shorter. *)

type terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; detail : Keeper_terminal_effect_detail.t
      }

type host_stop =
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }
(** A host-owned terminal that must stop a vendor-owned model loop after the
    current tool outcome has been returned. The Keeper bundle remains the
    authority for terminal effect completion/failure; this value carries only
    the transport stop reason. *)

val host_stop_failed : host_stop -> bool
(** [true] only for a terminal tool whose effect failed. A repeated tool call
    and a terminal tool that completed or deferred to a durable stimulus end
    the turn on purpose, and the Keeper settles them as completed or yielded
    turns, so a transport logs them as stops rather than failures. *)

type dynamic_tool_result =
  { success : bool
  ; content : string
  ; content_blocks : Llm_provider.Types.content_block list option
    (** Model-visible producer content. [None] selects the text fallback;
        [Some blocks] is preserved through client transport. *)
  ; abort_turn : host_stop option
    (** Host-owned terminal reason. The transport returns the current tool
        outcome, then stops the provider loop instead of admitting another
        tool call. The typed reason must remain a checkpoint terminal rather
        than being projected as a provider failure. *)
  ; on_response_sent : (unit -> unit) option
    (** Observe only the actual complete transport response write. Preparing or
        buffering a response, starting a tool, and receiving a vendor terminal
        do not invoke it. The callback is specific to this physical returned
        result and must not be looked up by a reusable client request ID.
        It is an observation of canonical projected content, not an ACK or a
        claim that the provider consumed the result. See [response_observer]. *)
  }

(** How a client should load one dynamic tool's definition. The Keeper's tool
    declaration ([defer_loading] in [config/tools/<name>.toml]) decides it; each
    transport writes it in its own wire form:
    - Claude Code: [_meta."anthropic/alwaysLoad" = true] for [Upfront]
      (code.claude.com/docs/en/mcp, "Exempt a server from deferral").
    - Codex app-server: [deferLoading] on the dynamic tool spec, [false] for
      [Upfront] (openai/codex [codex-rs/protocol/src/dynamic_tools.rs],
      [DynamicToolFunctionSpec.defer_loading]). *)
type loading =
  | Upfront  (** The definition is in the model's context from the start. *)
  | On_demand  (** Only the name is listed; the model loads it by searching. *)

(** How large one result of a dynamic tool can be when it reaches the client.
    The Keeper tool bundle knows it: a built-in, Skill composition or
    attached-service result is held to the inline ceiling of the
    {!Tool_output.model_projection} it crosses. Claude Code reads a bound as
    [_meta."anthropic/maxResultSizeChars"] (code.claude.com/docs/en/mcp); the
    ceiling is in bytes and a UTF-8 character is at least one byte, so the same
    number is a safe character count. *)
type result_bound =
  | Bounded_bytes of int  (** No result is longer than this many bytes. *)
  | Unbounded  (** MASC does not cap the result; nothing is declared. *)

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; loading : loading
  ; result_bound : result_bound
  ; execution_mode : Yojson.Safe.t -> Agent_core.Tool_contract.execution_mode
    (** Producer scheduling contract. Concurrent calls may overlap; Serial calls
        wait for earlier calls and fence later calls until settlement. *)
  ; call_effect : Yojson.Safe.t -> Agent_core.Tool.call_effect
      (** Pure, total producer contract for [call], valid even if [call] fails
          or is cancelled. It may be evaluated more than once before dispatch. *)
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

val dynamic_tool_bytes : dynamic_tool list -> int
(** [dynamic_tool_bytes tools] sums the name, description and serialized
    schema lengths. Bytes this process sends, not provider tokens. It counts
    [On_demand] tools too, so it bounds what the client holds, not what the
    model reads from the start: size [upfront_tools] for that. *)

val upfront_tools : dynamic_tool list -> dynamic_tool list
(** The [Upfront] tools of the list, in their order. A runtime sizes the result
    with its own [dynamic_tool_bytes], so the upfront share and the total are
    counted the same way. *)

type content_transport = Codex | Mcp

val append_host_text :
  dynamic_tool_result ->
  text:string ->
  limit:result_bound ->
  on_response_sent:(unit -> unit) ->
  dynamic_tool_result option
(** The result with a block of MASC's own text after the tool's, or [None] when
    [content] with the text would pass [limit]. A result without
    [content_blocks] carries the text in [content]; with them the blocks are
    what the client reads, so a [Text] block follows them, and [content] gets
    the same text so the two stay one view of the result. [text] is sanitized
    to valid UTF-8 first, and [limit] is judged on the sanitized text: repair
    can make it longer.

    The result's own [on_response_sent] still runs, and [on_response_sent]
    runs after it, both at the actual write of the whole response. The
    original result is a prefix of what is written, so a retention marker on it
    still describes delivered bytes. Appending is the last step on a result:
    an observer that parses [content] has seen it before. *)

val response_observer :
  content_transport -> dynamic_tool_result -> (unit -> unit) option
(** Bind the optional observer only when the original model-visible content
    can be projected without substitution or UTF-8 repair. [None] also covers
    results without an observer. Preparing this callback does not invoke it. *)

val notify_response_sent : (unit -> unit) option -> unit
(** Invoke after the complete response write. Observers must be short, pure
    state updates; they must not perform I/O. Ordinary observer exceptions are
    reported without reclassifying an already written response as undelivered.
    Reserved cancellation and operator interrupts still propagate. This is
    transport delivery evidence, never vendor consumption or permission to ACK. *)


val official_client_image_media_types : string list
(** The closed media-type set an official-client image item accepts, on either
    transport. {!validate_image_inputs} reads it, so a turn image and a
    tool-result image are judged by one list. *)

val validate_base64_image_data : string -> (unit, string) result
(** Shared initial-image and tool-result validation before client delivery. *)

(** One image attached to a turn's user message. [base64_data] is the raw
    base64 payload with no data-URL prefix and no newlines. *)
type image_input =
  { media_type : string
  ; base64_data : string
  }

val validate_image_input : where:string -> image_input -> (unit, string) result
(** Check one image. [where] names it in the error, such as [images[0]]. *)

val validate_image_inputs : image_input list -> (unit, string) result
(** Check a turn's images before the client starts. The error names the first
    bad image, as [images[N].media_type ...] or [images[N].base64_data ...]. *)

val project_content :
  content_transport -> content:string ->
  content_blocks:Llm_provider.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** Validate delivery before host settlement and terminal outcome selection. *)

val codex_content_items :
  content:string -> content_blocks:Llm_provider.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** Project tool text and images to the app-server's typed contentItems. An
    unsupported block is an explicit delivery error, not successful text-only
    evidence. [Some blocks] is authoritative; [None] uses [content]. *)

val mcp_content :
  content:string -> content_blocks:Llm_provider.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** MCP image content carries base64 bytes and mimeType. URL/file-id images
    require a separate resolver and are refused here rather than fetched. *)

val mcp_tool_result_content :
  success:bool -> content:string ->
  content_blocks:Llm_provider.Types.content_block list option ->
  Yojson.Safe.t list * bool
(** An MCP [tools/call] result's [content] items and its [isError]. When
    {!mcp_content} refuses a block the tool has already run, so the result
    carries the reason, then the sanitized [content], and reads as an error.
    Every MCP [tools/call] answer this server writes goes through here. *)
