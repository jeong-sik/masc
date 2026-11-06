(** Keeper_model_input_wire_bytes — how many bytes one provider's encoder
    sends for a message, to compare two forms of the same tool results
    (RFC-0363 §3.1.2).

    Providers send different bodies of one structured tool result, and some
    escape them twice:
    - Anthropic and Kimi send the [Text] blocks.
    - Gemini sends the [content], and with an image the blocks too, in a
      follow-up part.
    - OpenAI chat and GLM send the blocks as one JSON string inside the JSON
      request; with an image they send the [content] and the blocks in a
      follow-up message.
    - Responses sends the blocks as one JSON string; with an image, one part
      per block.
    - Ollama sends the blocks as one JSON string and moves images to
      [images].

    Whether a marker in place of a body makes a request smaller is therefore
    a question for the encoder that sends it, and
    {!Keeper_model_input_demotion.plan} asks it here. *)

val measurer :
  config:Agent_core.Llm_provider.Provider_config.t ->
  Agent_core.Types.message ->
  int option
(** [measurer ~config message] is the length of the body
    {!Agent_core.Llm_provider.Complete_common.serialize_http_request} builds
    for [config] from [message] alone, preceded by an assistant message that
    calls each of its tool results, with no tools.

    Media keep their place and type with an empty payload: two forms of one
    result carry the same media, so the payload cancels in a comparison, and
    reading it would put the media store's I/O inside the CPU-pool job that
    plans. The value is for comparing two forms of one message; it is not a
    request size.

    [None] when the encoder refuses the request, for whatever reason it
    gives. *)
