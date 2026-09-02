(** Impure shell of the [analyze_image] keeper tool.
    RFC-keeper-vision-delegation-tool §2.6.

    Loads an image artifact (raw bytes) from {!Multimodal.Vision_artifact_store},
    base64-encodes it into a one-shot [text; image] message, sub-calls
    configured vision runtimes in media-failover order, and classifies the reply
    via {!Multimodal.Vision_analyze}. The image is read only inside this sub-call;
    it never enters the keeper's own
    conversation. Every failure path is a typed JSON error — never a silent empty
    success (the failure class the RFC targets).

    Uses the shared {!Keeper_provider_subcall} boundary, so the tool owns no
    wall-clock cancellation layer.
    Artifact filesystem I/O is offloaded through {!Eio_guard.run_in_systhread}
    when the Eio runtime is active, so durable fsync/rename work does not block
    the shared Eio domain. *)

type complete_fn = Keeper_provider_subcall.complete_fn

val vision_default_max_tokens : unit -> int
(** Fallback output budget for the one-shot vision sub-call when the selected
    runtime has not configured [max_tokens]. Reads the
    [Env_config_keeper.KeeperVision.max_output_tokens] knob. *)

val max_image_bytes : unit -> int
(** Maximum raw artifact bytes accepted by the tool before base64 provider-message
    construction, from [MASC_KEEPER_VISION_MAX_IMAGE_BYTES] / runtime TOML boot
    overrides with a 5 MiB default matching dashboard upload policy. Oversized
    artifacts fail closed with [image_too_large]. *)

val supported_image_media_types : string list
(** MIME types admitted by [analyze_image]. The tool schema and runtime
    validation share this list. *)

val validate_media_type : string -> (string, string) result
(** Normalize and validate an image MIME type against
    {!supported_image_media_types}. *)

val validate_image_size : string -> (unit, string) result
(** Validate raw image bytes against {!max_image_bytes}. *)

val truncated_of_stop_reason : Agent_core.Types.stop_reason -> bool
(** Collapse the provider's typed terminal reason to the single [truncated] bit
    {!Multimodal.Vision_analyze.classify} consumes: [MaxTokens -> true], every
    other variant -> [false]. Exhaustive so a new agent-core variant forces a decision. *)

val message_of_request
  :  Multimodal.Vision_analyze.request
  -> Agent_core.Types.message
(** One-shot user message [text query; image], with bytes base64-encoded and
    [~source_type:Agent_core.Types.Base64] (the OpenAI/ollama serializer emits
    [data:<media_type>;base64,<data>]). *)

val provider_for_vision
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** A one-shot, non-thinking vision config: thinking off (avoids the
    2026-06-25 gemma4 thinking-budget exhaustion that produced empty replies),
    [response_format = Off]; its prompt specifies the JSON object and the
    response parser validates it, [tool_choice = None], the selected provider
    config's exact temperature
    (including omission), and a fallback [max_tokens] only when the selected
    runtime has not configured one. *)

val sniff_image_media_type : string -> (string, string) result
(** Identify an image's media type from its leading bytes. [Error] names the
    admitted set rather than guessing, so an unrecognised file is rejected at
    the boundary that read it. Shared with the TUI composer so both surfaces
    admit exactly the same formats. Pixel dimensions are
    {!Keeper_image_dimensions.image_dimensions}, kept apart so the chat store
    can measure an attachment without this tool's dependency cone. *)

val vision_runtime_ids : unit -> string list
(** Ordered image-capable runtime ids: [\[runtime\].media_failover] order
    first, then declaration order. The handler tries these candidates in order
    for timeout/provider failures within one cumulative tool deadline. *)

val first_vision_runtime_id : unit -> (string, string) result
(** Compatibility helper returning the first entry of {!vision_runtime_ids}, or
    [Error] when none is configured. *)

val vision_store_dir : keeper_name:string -> string
(** Per-keeper artifact store directory used by [analyze_image] and eager image
    eviction. *)

val store_artifact
  :  dir:string
  -> string
  -> (Multimodal.Vision_artifact_store.handle, string) result
(** Store image bytes in the content-addressed artifact store. Blocking
    filesystem work is offloaded when the Eio runtime is active. *)

(** Typed outcome of {!run_vision}. SSOT shared by the tool handler (renders to
    JSON) and eager ingestion eviction ({!Keeper_vision_ingest}, renders to a
    placeholder). *)
type vision_outcome =
  | Vo_ok of string
  | Vo_invalid_request of string
  | Vo_no_runtime of string
  | Vo_timeout
  | Vo_invalid_structured_response of string
  | Vo_provider of { failure_class : Tool_result.tool_failure_class; detail : string }
  | Vo_empty
  | Vo_truncated

val outcome_of_response : Agent_core.Types.api_response -> vision_outcome
(** Classify a provider response into a {!vision_outcome}. A reply the model
    truncated mid-JSON fails the structured parse before its text can be read;
    when the stop reason is a MaxTokens cut this is reported as [Vo_truncated]
    (remediation: a larger budget) rather than [Vo_invalid_structured_response],
    so the operator sees the real cause. Exposed for tests. *)

val run_vision
  :  ?complete:complete_fn
  -> sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> query:string
  -> media_type:string
  -> bytes:string
  -> unit
  -> vision_outcome
(** The one-shot vision sub-call core (runtime resolution + Provider-boundary
    call + §2.2 classification). Used by {!handle} and by eager ingestion.
    Non-cancellation exceptions are converted to
    [Vo_provider]; provider success whose text is malformed structured output
    is [Vo_invalid_structured_response] — unless the stop reason is a MaxTokens
    cut, which reads as [Vo_truncated] because the parse only failed on a reply
    the budget cut short. Either way eager ingestion can keep the turn alive
    with a typed unread placeholder. *)

val handle
  :  ?complete:complete_fn
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> string

val handle_with_outcome
  :  ?complete:complete_fn
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
(** Tool entry. [args] = [{ "artifact": handle; "query": string;
    "media_type"?: string }]. [media_type], when provided, must be a supported
    image MIME type; otherwise the stored bytes are sniffed fail-closed. Requires
    [sw], [net], and [clock]; missing Eio context is [Runtime_failure]. Returns a JSON
    string: [{"ok":true,"text":...}] or
    [{"ok":false,"error":code,"failure_class":class[,"detail":...]}] with code
    one of [invalid_args | eio_context_unavailable | artifact_load_failed |
    image_too_large | invalid_media_type | invalid_request |
    no_capable_runtime | timeout | provider_error | empty_extraction |
    truncated_extraction]. [complete] defaults to the live provider call (inject
    in tests). Never returns a raw empty success. *)
