(** Register provider-specific capacity probes.

    Side-effect only: registers [Cascade_openai_probe.Openai_probe] with
    {!Cascade_capacity_probe} at module initialisation time.

    Separated from {!Cascade_capacity_probe} to break the dependency cycle:
    [Cascade_capacity_probe → Cascade_openai_probe → Cascade_capacity_probe].

    @since 0.10.1 *)
