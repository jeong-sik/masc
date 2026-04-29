(** Oas_model_resolve — compatibility facade over
    {!Cascade_runtime}.

    Cascade ownership now lives under [lib/cascade/].  This
    module is a stable name preserved while internal callers
    migrate.  The facade re-exports {!Cascade_runtime} verbatim
    via [include module type of] — type identity is preserved,
    so callers can interleave [Oas_model_resolve.X] and
    [Cascade_runtime.X] freely.

    External callers (tests + observability contracts) reach
    {!Cascade_runtime.max_context_of_label},
    {!Cascade_runtime.provider_name_of_label},
    {!Cascade_runtime.resolve_primary_max_context} through this
    facade.  When all callers have migrated, this module can be
    deleted in one revert-safe commit. *)

include module type of Cascade_runtime
