(** Unified bidirectional image generation tool ([keeper_generate_image]).

    Resolves image-generation targets through
    {!Runtime_agent.image_generator_candidates} (active runtime ->
    [[runtime.media].image_generator] -> other configured image-output runtimes
    -> auto-derived sibling image endpoints for configured OpenAI, Gemini, Z.AI,
    and OpenRouter credentials), executes the target's typed contract
    ({!Llm_provider.Image_gen}, single-turn {!Llm_provider.Complete}, or
    single-turn official client via {!Fusion_official_client}), persists every
    generated image durably to {!Attachment_store}, and returns canonical
    attachment wire metadata alongside native [Image] content blocks. *)

type request = Llm_provider.Image_gen.request

type endpoint_generate_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  dialect:Llm_provider.Capabilities.images_api_dialect ->
  request ->
  (Llm_provider.Image_gen.generated_image list, Llm_provider.Http_client.http_error) result

type remote_fetch_fn =
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  max_bytes:int ->
  string ->
  (string, string) result

val parse_args : Yojson.Safe.t -> (request * string option, string) result
(** Parse and validate tool input JSON into [(request, requested_runtime_id)].
    Rejects empty prompts, out-of-range counts (outside 1..4), unknown
    [output_format], and unrecognized fields. *)

val sibling_provider_config
  :  Llm_provider.Provider_config.t
  -> model_id:string
  -> provider_id:string
  -> ?request_path:string
  -> unit
  -> Llm_provider.Provider_config.t
(** Derive a sibling image-generation {!Llm_provider.Provider_config.t} from an
    existing authorized provider configuration, preserving credentials, headers,
    and base URL while clearing model-specific capability overrides and chat
    thinking/tool controls. *)

val validate_remote_download_url : string -> (unit, string) result
(** Guard remote image URL fetches against non-HTTPS schemes, missing hosts,
    and loopback/private literal addresses. *)

val handle_with_outcome
  :  ?base_path:string
  -> ?active_runtime:Runtime_instance.t
  -> ?candidates:Runtime_agent.image_generator_target list
  -> ?generate_endpoint:endpoint_generate_fn
  -> ?complete_in_turn:Keeper_provider_subcall.complete_fn
  -> ?fetch_remote_url:remote_fetch_fn
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
