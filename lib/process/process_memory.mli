(** Current process resident memory, independent of the OCaml heap. *)
type source = Mach_task_info | Proc_statm
type sample = { resident_bytes : int64; source : source }

val resident_set : unit -> (sample, string) result
(** Reads this process's current RSS, never its historical maximum. Linux's
    [/proc/self/statm] is a kernel approximation. Call from a system thread
    when used in an Eio request path. Unsupported systems and failed probes
    return [Error], not a zero measurement. *)
