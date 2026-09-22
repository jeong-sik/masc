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

(** The credential a binding sends, as the binding resolved it. An exact
    request on a binding sends the key that binding's ordinary requests carry
    -- not a second read of an environment name, which the deployment's
    credential selection may resolve differently. An environment name that
    resolved to nothing stays named, so the refusal can say which one. *)
type binding_credential =
  | Credential_not_declared  (** The binding names no credential. *)
  | Credential_resolved of Secret.t
  | Credential_unresolved of { environment_variable : string }

(** One exact-output slot: the binding it names. The caller already holds that
    binding as the typed config its ordinary requests run on, so it arrives
    whole rather than as a field list this module copies -- the wire, the
    model, the capability override, the thinking and effort controls and the
    connect deadline are all read from it. Three defects came from copying a
    subset instead: the connect deadline (#37004), the declared effort
    (#37326) and the wire itself (#37674). [target_ref] is the slot id the
    lane configuration names, conventionally "<provider>.<model>". *)
type declared_target =
  { target_ref : string
  ; binding : Provider_config.t
  ; credential : binding_credential
  ; body_timeout_s : float option
      (** The exact request's body deadline. It is the one request fact a
          binding does not carry: ordinary requests stream, and this one does
          not. *)
  }

type resolver_catalog_input =
  | Embedded_default
  | Embedded_with_targets of declared_target list
      (** The embedded catalog for provider and model facts, plus the slots the
          caller declares. The embedded catalog carries no [[targets]] of its
          own, so these are the whole target set. *)
  | Full_replacement of catalog_document
  | Full_replacement_file of string
(** Which catalog bytes [load_resolver_snapshot] starts from. Embedded inputs
    use the packaged provider/model catalog and may add the complete set of
    runtime target bindings; a full replacement supplies the whole catalog,
    including its targets. Provider, model, and target identities must each be
    unique within the selected catalog. *)

type target_ref_error =
  | Empty_target_ref
  | Invalid_target_ref

type resolver_catalog_source =
  | Embedded_catalog
  | Full_replacement_catalog

type resolver_collision =
  | Duplicate_provider_identity
  | Duplicate_model_identity
  | Duplicate_target_identity
  | Provider_alias_shadow

type resolver_binding_component =
  | Target_provider
  | Target_model

type target_binding_policy =
  | Require_all_target_bindings
  | Exclude_unbound_targets

type rejected_target_binding =
  { target_ref : string
  ; component : resolver_binding_component
  }

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
(** Whether the selected model may serve an exact request at all —
    {!Exact_output_catalog_binding.target_model_admitted} applied to the
    target's own capabilities and catalog id. A [false] here becomes
    {!Exact_output_ready_admission.wire_admission_error.Unsupported_target_model}
    at admission. *)
val hash_parts : string list -> string
val option_float : float option -> string

val load_resolver_snapshot
  :  io:resolver_io
  -> ?target_binding_policy:target_binding_policy
  -> ?catalog:resolver_catalog_input
  -> unit
  -> (resolver_snapshot, resolver_snapshot_error) result
(** Read, parse, and freeze the target catalog in one step: every later stage
    resolves against this snapshot, so a run cannot mix catalog generations.
    Reads go through [io] (never the environment directly — an unread
    variable surfaces as {!Environment_read_failed}), and every declared
    target is bound and endpoint-checked under [target_binding_policy]:
    [Require_all_target_bindings] (the default) rejects the snapshot with
    {!Target_binding_missing} when a component is unbound, while
    [Exclude_unbound_targets] drops it and reports it via
    {!resolver_rejected_target_bindings}. The failure constructors
    {!Catalog_read_failed}, {!Catalog_parse_failed}, {!Target_catalog_invalid},
    {!Catalog_collision}, {!Target_binding_missing}, and
    {!Target_endpoint_invalid} partition everything this can reject. *)

val resolver_rejected_target_bindings
  :  resolver_snapshot
  -> rejected_target_binding list
(** Targets dropped by [Exclude_unbound_targets] at snapshot build time, in
    declaration order; empty under [Require_all_target_bindings]. *)

val admit_target_ref
  :  resolver_snapshot
  -> string
  -> (admitted_target, target_catalog_admission_error) result
(** Check a target reference against the frozen snapshot without reading any
    credential: fails with {!Target_ref_rejected} for a malformed or empty
    reference and {!Target_not_in_catalog} when no declared target carries
    it. The credential itself is only demanded later, by
    {!resolve_target}. *)

(** Return the credential-free immutable request projection captured by
    [admit_target_ref]. This value may be used only for pure wire-size
    projection; it cannot be dispatched or converted into a selected target. *)
val projection_target : admitted_target -> projection_target

val resolve_target : admitted_target -> (selected_target, target_selection_error) result
(** Demand and freeze the credential: the target's environment variable is
    read through the snapshot's [io] and a missing, empty, or unread value
    fails with {!Missing_target_credential}, {!Target_credential_invalid}, or
    {!Target_credential_read_failed}. On success the key is frozen into the
    [selected_target]; later stages never re-read the environment. *)
