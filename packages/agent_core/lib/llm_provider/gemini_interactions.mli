(** Shared response-envelope decoding for the Gemini Interactions API.

    Image generation and speech generation both consume Interactions
    responses; this module owns the modality-independent envelope — field
    readers, the usage block, the status gate, and the steps/model_output
    walker — so the two consumers cannot drift apart (oas#2633). Modality
    payloads (image sources, audio blocks) stay in their own modules and are
    injected as decoders.

    @stability Internal *)

(** Interaction usage block ([usage.total_*] fields). Absent fields stay
    [None] rather than becoming zero. *)
type usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; total_tokens : int option
  ; cached_tokens : int option
  ; thought_tokens : int option
  ; tool_use_tokens : int option
  }

(** Decoded envelope around one modality payload. *)
type 'payload response =
  { provider_response_id : string
  ; created_at_rfc3339 : string option
  ; payload : 'payload
  ; usage : usage option
  }

(** Typed parse failure attributed to [parser] (e.g. ["image_generation"]). *)
val parse_failure : parser:string -> string -> ('a, Http_client.http_error) result

(** A well-formed interaction whose status is not ["completed"]: a
    provider-reported outcome ([Unknown_provider_failure]), not a parser
    defect, so parse-error alarms stay meaningful. *)
val status_failure : string -> ('a, Http_client.http_error) result

(** [required_string ~parser name json]: missing/null reports
    ["%s is required"], a blank or non-string value reports
    ["%s must be non-empty"]. *)
val required_string
  :  parser:string
  -> string
  -> Yojson.Safe.t
  -> (string, Http_client.http_error) result

val optional_string
  :  parser:string
  -> string
  -> Yojson.Safe.t
  -> (string option, Http_client.http_error) result

val optional_int
  :  parser:string
  -> string
  -> Yojson.Safe.t
  -> (int option, Http_client.http_error) result

(** Decode the interaction [usage] object; [`Null]/absent is [Ok None]. *)
val usage_of_json
  :  parser:string
  -> Yojson.Safe.t
  -> (usage option, Http_client.http_error) result

(** Walk [steps]: skip [thought] steps, and inside every [model_output] step
    decode each content item of [content_type] with [item_of_json]. Any other
    step or content type fails closed. Returns items in wire order; emptiness
    is the caller's policy. *)
val model_output_items
  :  parser:string
  -> content_type:string
  -> item_of_json:(Yojson.Safe.t -> ('a, Http_client.http_error) result)
  -> Yojson.Safe.t
  -> ('a list, Http_client.http_error) result

(** Decode one raw Interactions body through the shared total JSON boundary
    ({!Json_util.decode_json_with}): required [id], the ["completed"] status
    gate, optional [created], the injected payload, then [usage]. *)
val decode_envelope
  :  parser:string
  -> payload_of_json:(Yojson.Safe.t -> ('p, Http_client.http_error) result)
  -> string
  -> ('p response, Http_client.http_error) result
