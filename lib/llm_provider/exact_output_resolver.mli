type catalog_generation
type catalog_evidence
type target_identity
type resolver_snapshot
type admitted_target

type projection_target = private
  { config : Provider_config.t
  ; capabilities : Capabilities.capabilities
  ; anthropic_thinking_control : Capabilities.anthropic_thinking_control option
  ; body_timeout_s : float option
  ; model_admitted : bool
  }

type resolver_io = { getenv : string -> (string option, unit) result }

type catalog_document =
  { source : string
  ; contents : string
  }

type resolver_catalog_input =
  | Embedded_default
  | Embedded_with_overlay of catalog_document
  | Full_replacement of catalog_document
  | Full_replacement_file of string

type target_ref_error =
  | Empty_target_ref
  | Invalid_target_ref

type resolver_catalog_source =
  | Embedded_catalog
  | Full_replacement_catalog
  | Overlay_catalog

type resolver_collision =
  | Duplicate_provider_identity
  | Duplicate_model_identity
  | Duplicate_target_identity
  | Provider_alias_shadow
  | Target_identity_shadow
  | Model_identity_shadow

type resolver_binding_component =
  | Target_provider
  | Target_model

type resolver_endpoint_error =
  | Malformed_base_url
  | Base_url_userinfo_not_allowed
  | Base_url_query_not_allowed
  | Base_url_fragment_not_allowed
  | Invalid_request_path
  | Unsupported_gemini_request_path
  | Invalid_gemini_model_path

type resolver_snapshot_error =
  | Catalog_read_failed of
      { path : string
      ; detail : string
      }
  | Catalog_parse_failed of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Target_catalog_invalid of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Catalog_collision of resolver_collision
  | Target_binding_missing of
      { target_ref : string
      ; component : resolver_binding_component
      }
  | Target_endpoint_invalid of
      { target_ref : string
      ; cause : resolver_endpoint_error
      }
  | Environment_read_failed of { environment_variable : string }

type selected_target = private
  { config : Provider_config.t
  ; capabilities : Capabilities.capabilities
  ; anthropic_thinking_control : Capabilities.anthropic_thinking_control option
  ; body_timeout_s : float option
  ; identity : target_identity
  ; generation : catalog_generation
  ; evidence : catalog_evidence
  }

type target_selection_error =
  | Missing_target_credential of
      { target_ref : string
      ; environment_variable : string
      }
  | Target_credential_invalid of
      { target_ref : string
      ; environment_variable : string
      }
  | Target_credential_read_failed of
      { target_ref : string
      ; environment_variable : string
      }

type target_catalog_admission_error =
  | Target_ref_rejected of target_ref_error
  | Target_not_in_catalog of string

val catalog_generation_fingerprint : catalog_generation -> string
val catalog_evidence_sha256 : catalog_evidence -> string
val resolver_catalog_generation : resolver_snapshot -> catalog_generation
val resolver_catalog_evidence : resolver_snapshot -> catalog_evidence
val target_identity_fingerprint : target_identity -> string
val admitted_target_identity : admitted_target -> target_identity
val admitted_target_catalog_generation : admitted_target -> catalog_generation
val admitted_target_catalog_evidence : admitted_target -> catalog_evidence
val selected_target_identity : selected_target -> target_identity
val selected_target_catalog_generation : selected_target -> catalog_generation
val selected_target_catalog_evidence : selected_target -> catalog_evidence
val selected_target_model_admitted : selected_target -> bool
val hash_parts : string list -> string
val option_float : float option -> string

val load_resolver_snapshot
  :  io:resolver_io
  -> ?catalog:resolver_catalog_input
  -> unit
  -> (resolver_snapshot, resolver_snapshot_error) result

val admit_target_ref
  :  resolver_snapshot
  -> string
  -> (admitted_target, target_catalog_admission_error) result

(** Return the credential-free immutable request projection captured by
    [admit_target_ref]. This value may be used only for pure wire-size
    projection; it cannot be dispatched or converted into a selected target. *)
val projection_target : admitted_target -> projection_target

val resolve_target : admitted_target -> (selected_target, target_selection_error) result
