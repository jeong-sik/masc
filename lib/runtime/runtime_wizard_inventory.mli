(** JSON projection of every enabled declared binding, including runtimes whose
    credential or executable is unavailable. Credential values and file paths
    are omitted by default; credential values are never projected. Undeclared context limits stay null.

    [integrations] independently projects configured providers, AGENT_CORE
    provider prototypes, and named CLI/local-server transports. Setup and
    verification support describe adapter capability, never account access or
    measured readiness. Unsupported protocols remain visible with null protocol
    or unsupported status. Catalog endpoint credentials are also redacted. *)
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
