(** JSON projection of every enabled declared binding, including runtimes whose
    credential or executable is unavailable. Credential values and file paths
    are omitted by default; credential values are never projected. Undeclared context limits stay null.

    [default_runtime_selection] contains concrete candidates of the configured
    default lane in declared order, or the concrete default itself. The separate
    [default_runtime_id] preserves the route name; unrelated enabled bindings
    are not selected.

    [integrations] independently projects configured providers, AGENT_CORE
    provider prototypes, and named CLI/local-server transports. Setup and
    verification support describe adapter capability, never account access or
    measured readiness. Unsupported protocols remain visible with null protocol
    or unsupported status. Catalog endpoint credentials are also redacted.

    [account_groups] groups configured official-client providers by the same
    typed credential-location quota scope their runtime uses. Its opaque [id]
    is [Runtime_quota_window.scope_id], shared with Runtime and Usage history.
    [integration_ids] and [runtime_ids] preserve every declared provider/binding.
    Groups are presentation identities, never mutation targets, provider account
    IDs or email-based guesses; credentials changing in place retain the scope. *)
val to_json : ?include_credential_references:bool -> Runtime_schema.config -> Yojson.Safe.t
(** [include_credential_references] is for the local setup CLI only. It adds
    file references, never secret values, so new model bindings can preserve
    protected credentials. HTTP callers leave it false. *)

val binding_for_provider
  :  Runtime_schema.config
  -> Runtime_schema.provider
  -> (Runtime_schema.binding, string) result
(** The binding the install wizard offers for this provider: its declared
    [wizard-default], the only enabled binding when there is exactly one, or
    the one [runtime].default already names. Anything else is a real choice
    the wizard will not guess. The installer and the seed-config guard read
    the same rule from here. *)

val provider_model_rows : string -> (Yojson.Safe.t, string) result
(** Curated catalog rows for one named provider, for the setup wizard's named
    catalog sources: id, label, declared context, accepted reasoning efforts
    with a default rung, and capabilities resolved against the provider's own
    wire kind. Rows without a positive declared context are omitted — the
    wizard cannot pin a runtime entry for them. An unknown provider id is an
    [Error] naming the installed providers. *)
