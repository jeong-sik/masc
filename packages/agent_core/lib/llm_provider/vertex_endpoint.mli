(** Native Vertex Gemini publisher endpoint. Authentication is supplied via
    [Provider_config.Bearer_token]; this module does not acquire ADC credentials
    or claim account/model access. *)
type location = Global | Regional of string
val base_url : project:string -> location:location -> (string, string) result
(** Prefix consumed by the existing native Gemini generateContent/stream codec.
    Project and region are explicit resource identifiers, never inferred from
    a model name.
    {{:https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference}Official inference reference}. *)

val parse_base_url : string -> ((string * location), string) result
(** Validate an exact native Google publisher prefix before attaching ADC. *)
