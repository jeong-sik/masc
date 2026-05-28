(** Cascade_probe_init — register provider-specific capacity probes.

    Separated from [Cascade_capacity_probe] to break the dependency cycle:
      Cascade_capacity_probe → Cascade_openai_probe → Cascade_capacity_probe

    This module depends on both [Cascade_capacity_probe] and
    [Cascade_openai_probe], but neither depends on it, so no cycle.

    @since 0.10.1 *)

let () = Cascade_capacity_probe.register
           (module Cascade_openai_probe.Openai_probe)
