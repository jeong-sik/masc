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
      ; diagnostic : string
      }

type host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }
(** A host-owned terminal that must stop a vendor-owned model loop after the
    current tool outcome has been returned. The Keeper bundle remains the
    authority for terminal effect completion/failure; this value carries only
    the transport stop reason. *)

type dynamic_tool_result =
  { success : bool
  ; content : string
  ; content_blocks : Agent_core.Types.content_block list option
    (** Model-visible producer content. [None] selects the text fallback;
        [Some blocks] is preserved through client transport. *)
  ; abort_turn : host_stop option
    (** Host-owned terminal reason. The transport returns the current tool
        outcome, then stops the provider loop instead of admitting another
        tool call. The typed reason must remain a checkpoint terminal rather
        than being projected as a provider failure. *)
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

val dynamic_tool_bytes : dynamic_tool list -> int
(** [dynamic_tool_bytes tools] sums the name, description and serialized
    schema lengths. Bytes this process sends, not provider tokens. *)

type content_transport = Codex | Mcp

val official_client_image_media_types : string list
(** The closed media-type set an official-client image item accepts, on either
    transport. Shared with {!Runtime_codex_app_server.validate_images} and
    {!Runtime_claude_code.validate_images} so a turn image and a tool-result
    image are judged by one list. *)

val project_content :
  content_transport -> content:string ->
  content_blocks:Agent_core.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** Validate delivery before host settlement and terminal outcome selection. *)

val codex_content_items :
  content:string -> content_blocks:Agent_core.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** Project tool text and images to the app-server's typed contentItems. An
    unsupported block is an explicit delivery error, not successful text-only
    evidence. [Some blocks] is authoritative; [None] uses [content]. *)

val mcp_content :
  content:string -> content_blocks:Agent_core.Types.content_block list option ->
  (Yojson.Safe.t list, string) result
(** MCP image content carries base64 bytes and mimeType. URL/file-id images
    require a separate resolver and are refused here rather than fetched. *)
