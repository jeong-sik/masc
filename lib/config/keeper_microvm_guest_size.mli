(** The memory and CPU count a keeper's microVM guest boots with.

    Both arrive as operator text -- a keeper TOML, [runtime.toml], or the
    environment -- and leave as runtime CLI argv. The value in between is
    typed, so a spelling the runtimes would read differently never reaches a
    boot, and two sizes compare as numbers rather than as the strings an
    operator happened to write ("2g" and "2048m" are one size). *)

type memory
(** Whole MiB, greater than zero. *)

val memory_of_string : string -> (memory, string) result
(** A positive decimal integer followed by exactly one of [m]/[M] (MiB) or
    [g]/[G] (GiB): ["512m"], ["8g"]. No whitespace, sign, fraction, bare
    number or other suffix. A bare number is refused because [container]
    reads it as bytes and Docker's grammar does too, which is not what an
    operator writing ["8"] means. The error names the value and this form.

    Only the arithmetic bounds the size from above: a value that would
    overflow [int] is refused. A size larger than the host can give is not,
    and the runtime refuses it at boot instead. The host's capacity is not a
    fact this module is given, and a ceiling written here would be a number
    about one machine. *)

val memory_mib : memory -> int

val memory_argv : memory -> string
(** ["<mib>m"]. [container run --memory] takes MiB granularity with a binary
    suffix, [msb run --memory] documents ["512M, 1G"], and [nerdctl run
    --memory] takes Docker's spelling of the same thing. Read 2026-09-18 off
    [container] 1.3.1 and [msb] 0.6.16: both took ["8192m"] and ["512M"] past
    argument parsing, so one lower-case spelling serves all three. *)

type cpus
(** A CPU count greater than zero. *)

val cpus_of_int : int -> (cpus, string) result
(** Refuses zero and negatives, naming the value and the accepted form. *)

val cpus_of_string : string -> (cpus, string) result
(** Decimal digits only (["4"]), greater than zero. For a value read from the
    environment, where there is no TOML integer to carry the type. The error
    quotes the text as written. *)

val cpus_count : cpus -> int

type t =
  { memory : memory
  ; cpus : cpus
  }

val equal : t -> t -> bool

val to_string : t -> string
(** ["memory=<mib>m cpus=<n>"], for a log line. *)

val resolve :
  memory:memory option ->
  cpus:cpus option ->
  default_memory:(unit -> (memory, string) result) ->
  default_cpus:(unit -> (cpus, string) result) ->
  (t, string) result
(** Per dimension, the keeper's own value when it set one, otherwise the
    default. A default is read only for a dimension the keeper left unset, so
    an unreadable workspace default refuses exactly the keepers that lean on
    it. Both unreadable defaults are reported together. *)
