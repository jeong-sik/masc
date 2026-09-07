external monotonic_seconds : unit -> float = "ocaml_shim_monotonic_seconds"

let elapsed_seconds = monotonic_seconds
