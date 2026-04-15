(** Oas_model_resolve — compatibility wrapper over {!Cascade_runtime}.

    Cascade ownership now lives under [lib/cascade/]. Keep this module as a
    stable facade while internal callers migrate to {!Cascade_runtime}. *)

include Cascade_runtime
