(** Phonebook types — public interface. *)

type cascade_server_flavor =
  | Llama_cpp | Ollama | Vllm | Provider_d_wire | Provider_g_wire | Provider_k_zai | Provider_h_wire
[@@deriving show, eq]

val flavor_of_string : string -> cascade_server_flavor option
(** Parse a flavor string.  Returns [None] for unknown values.

    Prefer this over {!flavor_of_string_exn}.  The exn variant exists
    only for backward-compat callers that already wrap their use site
    in a top-level [Failure] handler. *)

val flavor_of_string_exn : string -> cascade_server_flavor
(** Partial — raises [Failure] on unknown values. *)

val flavor_to_string : cascade_server_flavor -> string

type cascade_protocol =
  | Openai_http | Ollama_http | Provider_a_http | Openai_cli
[@@deriving show, eq]

val protocol_of_string : string -> cascade_protocol option
(** Parse a protocol string.  Returns [None] for unknown values.

    Prefer this over {!protocol_of_string_exn}. *)

val protocol_of_string_exn : string -> cascade_protocol
(** Partial — raises [Failure] on unknown values. *)

val protocol_to_string : cascade_protocol -> string

type cascade_phonebook_provider = {
  id : string;
  endpoint : string;
  protocol : cascade_protocol;
  flavor : cascade_server_flavor;
  auth_env : string option;
  note : string option;
}
[@@deriving show, eq]

type cascade_thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | Reasoning_effort
  | Reasoning_param
  | Chat_template_kwargs
  | Reasoning_content
[@@deriving show, eq]

type phonebook_model_capabilities = {
  max_output_tokens : int option;
  supports_tool_choice : bool;
  supports_extended_thinking : bool;
  supports_reasoning_budget : bool;
  thinking_control_format : cascade_thinking_control_format;
  supports_image_input : bool;
  supports_structured_output : bool;
  supports_native_streaming : bool;
}
[@@deriving show, eq]

val phonebook_model_capabilities_default : phonebook_model_capabilities

type cascade_phonebook_model = {
  id : string;
  provider : string;
  model_id : string;
  capabilities : phonebook_model_capabilities;
  note : string option;
}
[@@deriving show, eq]

type diversity_constraint =
  | Diverse_from_primary | Same_provider | Any_available
[@@deriving show, eq]

type cascade_phonebook_tier_group = {
  name : string;
  members : string list;
  weight : int;
  constraint_ : diversity_constraint option;
  note : string option;
}
[@@deriving show, eq]

type cascade_phonebook_defaults = {
  max_output_tokens : int;
  default_thinking_budget : int;
}
[@@deriving show, eq]

type cascade_phonebook = {
  defaults : cascade_phonebook_defaults;
  providers : cascade_phonebook_provider list;
  models : cascade_phonebook_model list;
  tier_groups : cascade_phonebook_tier_group list;
}
[@@deriving show, eq]

val provider_of_id : cascade_phonebook -> string -> cascade_phonebook_provider option
val model_of_id : cascade_phonebook -> string -> cascade_phonebook_model option
val tier_group_of_name : cascade_phonebook -> string -> cascade_phonebook_tier_group option
val models_of_tier_group :
  cascade_phonebook -> cascade_phonebook_tier_group -> cascade_phonebook_model list
val provider_of_model :
  cascade_phonebook -> cascade_phonebook_model -> cascade_phonebook_provider option
