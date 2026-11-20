(** Provider identity rows embedded in the model catalog TOML. *)

type capability_policy =
  | Models_only
  | Provider_defaults of
      { base : Capability_preset.t
      ; by_identity_kind : (Provider_kind.t * Capability_preset.t) list
      }
(** A model-only provider cannot carry a wire-wide preset, including when a
    caller constructs a typed declaration or a private catalog lookup view. *)

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; identity_kinds : Provider_kind.t list
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
  ; default_model : string option
  ; discovery_timeout_s : float option
    (** Caller-declared total deadline for one discovery HTTP request.
        [None] declares no deadline; it never grants an implicit unbounded one. *)
  ; capability_policy : capability_policy
    (** Wire overrides, when present in [Provider_defaults], have keys from
        [identity_kinds]; absent keys inherit the declared [base]. *)
  ; supports_parallel_tool_suppression : bool
    (** The provider documents a request control that limits a response to at
        most one tool call. Missing declarations are false; this is separate
        from a model being able to generate parallel tool calls. *)
  ; supports_extended_cache_ttl : bool
    (** The provider documents the one-hour prompt-cache lifetime that
        [Provider_config.cache_extended_ttl] asks for. Missing declarations
        are false: an endpoint that speaks the same wire does not thereby
        accept the [ttl] field. *)
  ; cache_session_wire : Capability_vocab.cache_session_wire
    (** Wire field used by this provider to carry a caller-supplied prompt-cache
        routing session key. Missing declarations default to
        {!Capability_vocab.No_cache_session_wire}. *)
  ; serves_bare_models : Model_identifiers.Model_id.t list
    (** Explicit exact provider-independent model IDs served by this endpoint.
        Authorization uses ASCII case equality, never a family prefix. Absence or an empty list grants no
        bare-row authority. The request model id alone cannot grant it, and
        capability manifests are outside this declaration. *)
  }

val parse_entry : Otoml.t -> (entry, string) result
(** Identity, kind, endpoint, path, auth and capability declaration are required.
    [capabilities_base = "models_only"] is the explicit model-only choice;
    omission never derives a preset from the provider id or wire kind. *)
