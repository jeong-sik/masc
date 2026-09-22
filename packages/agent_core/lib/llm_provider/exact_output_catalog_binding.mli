type exact_binding_error =
  | Provider_missing
      (** No provider entry in the catalog has the id passed as
          [~provider_ref]. *)
  | Model_missing
      (** No model entry of that provider declares the id passed as
          [~model_id]. Exact binding is identity-based, not prefix-based:
          the whole id must match. *)

type endpoint_error =
  | Malformed_base_url
  | Base_url_userinfo_not_allowed
  | Base_url_query_not_allowed
  | Base_url_fragment_not_allowed
  | Invalid_request_path
  | Unsupported_gemini_request_path
  | Invalid_gemini_model_path

val has_control : string -> bool
val validate_base_url : string -> (unit, endpoint_error) result

val validate_request_path
  :  kind:Provider_config.provider_kind
  -> string
  -> (unit, endpoint_error) result

val validate_model_path
  :  Provider_config.provider_kind
  -> string
  -> (unit, endpoint_error) result

val target_string_field
  :  target_label:string
  -> field:string
  -> Otoml.t
  -> (string, string) result

val target_float_field
  :  target_label:string
  -> field:string
  -> Otoml.t
  -> (float option, string) result

val target_bool_field
  :  target_label:string
  -> field:string
  -> Otoml.t
  -> (bool option, string) result

val target_positive_int_field
  :  target_label:string
  -> field:string
  -> Otoml.t
  -> (int option, string) result

val validate_timeout
  :  target_label:string
  -> field:string
  -> float option
  -> (unit, string) result

val model_identities_unique : Model_catalog.model_entry list -> bool
(** [true] when no two entries share the provider/model identity — the
    precondition that makes exact binding in {!resolve_exact} unambiguous. *)

val validate_overlay_model_identities
  :  base:Model_catalog.model_entry list
  -> overlay:Model_catalog.model_entry list
  -> bool

val resolve_exact
  :  catalog:Model_catalog.t
  -> model_entries:Model_catalog.model_entry list
  -> provider_ref:string
  -> model_id:string
  -> ( Model_catalog.provider_entry * Model_catalog.model_entry
       , exact_binding_error )
       result
(** Exact identity binding: the provider is found by [provider.id =
    provider_ref] and the model by [entry.provider_name = provider.id] and
    [entry.id_prefix = model_id] — the id is compared whole, despite the
    field name. Callers holding a display or api_name (the label a gateway
    shows) must not pass it here; resolve that label to the catalog id
    first. Fails with {!Provider_missing} or {!Model_missing}. *)

val merge_exact_model_entries
  :  base:Model_catalog.model_entry list
  -> overlay:Model_catalog.model_entry list
  -> Model_catalog.model_entry list

val compare_model_entries : Model_catalog.model_entry -> Model_catalog.model_entry -> int
val bool_string : bool -> string
val option_int : int option -> string
val task_string : Capabilities.task option -> string

val anthropic_thinking_control_string
  :  Capabilities.anthropic_thinking_control option
  -> string

val target_model_admitted : Capabilities.capabilities -> model_id:string -> bool
(** Whether the model may serve an exact request at all: [true] when the
    capability row declares no [supported_models] list at all, otherwise
    [true] only when [model_id] appears in it. Admission turns a [false]
    here into {!Exact_output_ready_admission.wire_admission_error.Unsupported_target_model}.
    Compare ids against this function, never against an api_name. *)

val catalog_anthropic_thinking_control
  :  Capability_vocab.anthropic_thinking_control option
  -> Capabilities.anthropic_thinking_control option

val capabilities_of_catalog_binding
  :  ?wire:Provider_config.provider_kind
  -> Model_catalog.provider_entry
  -> Model_catalog.model_entry
  -> Capabilities.capabilities
(** [wire] is the provider wire the caller's binding reaches. A provider row
    can name a different capability base per wire
    ([[providers]] capabilities_base_by_identity_kind), and only a binding
    knows which one this deployment speaks. Omitting it keeps the row's own
    base. *)

val anthropic_thinking_control_of_model
  :  Model_catalog.model_entry
  -> Capabilities.anthropic_thinking_control option

val functional_capability_projection
  :  Capabilities.capabilities
  -> anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> string list
