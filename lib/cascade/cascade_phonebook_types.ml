(** Phonebook types for the Cascade Phonebook/Switchboard RFC.

    TOML = Phonebook (what exists), OAS = Switchboard (who to use).
    This module defines ONLY the Phonebook side: providers, models,
    tier-groups. All routing logic lives in {!Cascade_routing_policy}.

    Design: ~150 lines of TOML config, zero routing intelligence. *)

(* ── Flavor ──────────────────────────────────────────────────── *)

(** Server flavor — determines request/response wire format.

    Stored in TOML as a string hint per provider. The OAS Switchboard
    selects the correct adapter based on this value.

    Not a TOML concern: OAS code decides how to use the flavor. *)
type cascade_server_flavor =
  | Llama_cpp    (** llama.cpp server: chat_template_kwargs, grammar, reasoning_budget *)
  | Ollama       (** ollama: /api/chat native, think, done_reason, arguments=JSON object *)
  | Vllm         (** vLLM: extra_body, guided_json, guided_grammar, prefix_cached *)
  | Provider_d_wire       (** canonical: SSE, reasoning_effort, web_search, parallel_tool_calls *)
  | Provider_g_wire    (** DeepSeek: thinking param, reasoning_content, reasoning_effort high/max *)
  | Provider_k_zai      (** Z.AI/GLM: reasoning_content, business errors 1301/1302/1303 *)
  | Provider_h_wire         (** Provider_h_wire/Provider_h: OpenAI compat, tools+stream incompatible *)
[@@deriving show, eq]

let flavor_of_string = function
  | "llama-cpp" -> Some Llama_cpp
  | "ollama" -> Some Ollama
  | "vllm" -> Some Vllm
  | "provider_d" -> Some Provider_d_wire
  | "provider_g" -> Some Provider_g_wire
  | "zai-provider_k" -> Some Provider_k_zai
  | "provider_h" -> Some Provider_h_wire
  | _ -> None

let flavor_of_string_exn s =
  match flavor_of_string s with
  | Some f -> f
  | None -> failwith (Printf.sprintf "Unknown server flavor: %s" s)

let flavor_to_string = function
  | Llama_cpp -> "llama-cpp"
  | Ollama -> "ollama"
  | Vllm -> "vllm"
  | Provider_d_wire -> "provider_d"
  | Provider_g_wire -> "provider_g"
  | Provider_k_zai -> "zai-provider_k"
  | Provider_h_wire -> "provider_h"

(* ── Protocol ────────────────────────────────────────────────── *)

type cascade_protocol =
  | Openai_http     (** OpenAI-compatible HTTP (/v1/chat/completions) *)
  | Ollama_http     (** Ollama native HTTP (/api/chat) *)
  | Provider_a_http  (** Provider_a Messages API (/v1/messages) *)
  | Openai_cli      (** CLI wrapper speaking OpenAI protocol *)
[@@deriving show, eq]

let protocol_of_string = function
  | "provider_d-http" -> Some Openai_http
  | "ollama-http" -> Some Ollama_http
  | "provider_a-http" -> Some Provider_a_http
  | "provider_d-cli" -> Some Openai_cli
  | _ -> None

let protocol_of_string_exn s =
  match protocol_of_string s with
  | Some p -> p
  | None -> failwith (Printf.sprintf "Unknown protocol: %s" s)

let protocol_to_string = function
  | Openai_http -> "provider_d-http"
  | Ollama_http -> "ollama-http"
  | Provider_a_http -> "provider_a-http"
  | Openai_cli -> "provider_d-cli"

(* ── Provider ────────────────────────────────────────────────── *)

type cascade_phonebook_provider =
  { id : string
  ; endpoint : string
  ; protocol : cascade_protocol
  ; flavor : cascade_server_flavor
  ; auth_env : string option
  ; note : string option
  }
[@@deriving show, eq]

(* ── Thinking Control Format ─────────────────────────────────── *)

(** Re-export from cascade_declarative_types for backward compat.
    The phonebook reuses the same wire-format taxonomy. *)
type cascade_thinking_control_format =
  | No_thinking_control
  | Thinking_object  (** DeepSeek: {"thinking":{"type":"enabled"}} *)
  | Reasoning_effort (** OpenAI o-series: {"reasoning_effort":"high"} *)
  | Reasoning_param  (** DeepSeek-style reasoning_effort param *)
  | Chat_template_kwargs (** llama.cpp: {"chat_template_kwargs":{"enable_thinking":bool}} *)
  | Reasoning_content  (** Z.AI/GLM: reasoning_content field in response *)
[@@deriving show, eq]

(* ── Model Capabilities (reused from cascade_declarative_types) ── *)

(** Per-model capabilities carried in the phonebook.

    Subset of the full cascade_model_capabilities that the Switchboard
    needs for routing decisions. Extended capabilities (prompt caching,
    multimodal, etc.) are still read from cascade_declarative_types
    for backward compatibility during migration. *)
type phonebook_model_capabilities =
  { max_output_tokens : int option
  ; supports_tool_choice : bool
  ; supports_extended_thinking : bool
  ; supports_reasoning_budget : bool
  ; thinking_control_format : cascade_thinking_control_format
  ; supports_image_input : bool
  ; supports_structured_output : bool
  ; supports_native_streaming : bool
  }
[@@deriving show, eq]

let phonebook_model_capabilities_default =
  { max_output_tokens = None
  ; supports_tool_choice = false
  ; supports_extended_thinking = false
  ; supports_reasoning_budget = false
  ; thinking_control_format = No_thinking_control
  ; supports_image_input = false
  ; supports_structured_output = false
  ; supports_native_streaming = false
  }
[@@deriving show, eq]

(* ── Model ───────────────────────────────────────────────────── *)

type cascade_phonebook_model =
  { id : string
  ; provider : string
  ; model_id : string
  ; capabilities : phonebook_model_capabilities
  ; note : string option
  }
[@@deriving show, eq]

(* ── Diversity Constraint ────────────────────────────────────── *)

(** Constraint for selecting models from non-primary tier-groups.
    The Switchboard enforces these when resolving task routing. *)
type diversity_constraint =
  | Diverse_from_primary  (** Must use different provider than primary *)
  | Same_provider         (** Must use same provider (internal fallback) *)
  | Any_available         (** No constraint *)
[@@deriving show, eq]

(* ── Tier-Group ──────────────────────────────────────────────── *)

(** Sole routing unit. OAS selects tier-groups per task_use.
    No model-level or provider-level selection in the phonebook. *)
type cascade_phonebook_tier_group =
  { name : string
  ; members : string list  (** Model IDs from [models.*] *)
  ; weight : int
  ; constraint_ : diversity_constraint option
  ; note : string option
  }
[@@deriving show, eq]

(* ── Phonebook Config (top-level) ────────────────────────────── *)

type cascade_phonebook_defaults =
  { max_output_tokens : int
  ; default_thinking_budget : int
  }
[@@deriving show, eq]

(** Phonebook — what providers/models exist. No routing logic. *)
type cascade_phonebook =
  { defaults : cascade_phonebook_defaults
  ; providers : cascade_phonebook_provider list
  ; models : cascade_phonebook_model list
  ; tier_groups : cascade_phonebook_tier_group list
  }
[@@deriving show, eq]

(* ── Lookup helpers ──────────────────────────────────────────── *)

let provider_of_id (pb : cascade_phonebook) (id : string) :
    cascade_phonebook_provider option =
  List.find_opt (fun (p : cascade_phonebook_provider) -> p.id = id) pb.providers

let model_of_id (pb : cascade_phonebook) (id : string) :
    cascade_phonebook_model option =
  List.find_opt (fun (m : cascade_phonebook_model) -> m.id = id) pb.models

let tier_group_of_name (pb : cascade_phonebook) (name : string) :
    cascade_phonebook_tier_group option =
  List.find_opt (fun (tg : cascade_phonebook_tier_group) -> tg.name = name)
    pb.tier_groups

let models_of_tier_group (pb : cascade_phonebook) (tg : cascade_phonebook_tier_group) :
    cascade_phonebook_model list =
  List.filter_map
    (fun mid -> model_of_id pb mid)
    tg.members

let provider_of_model (pb : cascade_phonebook) (m : cascade_phonebook_model) :
    cascade_phonebook_provider option =
  provider_of_id pb m.provider
