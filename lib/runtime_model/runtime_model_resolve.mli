(** Explicit model selector and custom endpoint parsing.
    Declared defaults belong to AGENT_CORE's selected binding. The caller may
    supplement a defaultless Ollama [auto] with discovery scoped to that binding's
    exact endpoint; no ambient endpoint or other provider's model is inferred. *)

type model_selector =
  | Concrete of string
  | Auto

val model_selector_of_string : string -> model_selector

type custom_model_error =
  | Missing_endpoint
  | Empty_model
  | Invalid_endpoint

val custom_model_error_to_string : custom_model_error -> string

(** Parse an explicit [model@url] custom HTTP model selection.
    Both model and an absolute HTTP(S) endpoint are required. No process
    environment or discovery state supplies an omitted endpoint. An explicit
    numeric port must survive parsing and lie within the TCP port range 1–65535.
    The model
    and URL are trimmed at the boundary; URL path/query bytes are preserved. *)
val parse_custom_model : string -> (string * string, custom_model_error) result
