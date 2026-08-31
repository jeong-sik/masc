(** Byte-budget contract for the dynamic Memory OS fact payload.

    The measured bytes are exactly the UTF-8 bytes that recall places in the
    [facts] template variable: category, record time, claim, separators, and
    line breaks. No identity is rendered — selection happens through the
    Librarian's per-pass surrogate ids. Prompt-template boilerplate is
    deliberately outside this policy. *)

type measurement =
  { actual_bytes : int
  ; max_bytes : int
  }

type fit =
  | Fits of measurement
  | Exceeds of measurement

val render_facts : Keeper_memory_os_types.fact list -> string
val render_fact : Keeper_memory_os_types.fact -> string
val rendered_bytes : Keeper_memory_os_types.fact list -> int
(** Exact byte count of {!render_facts}, computed without allocating the
    combined rendered payload. Saturates at [Int.max_int]. *)

val measure : max_bytes:int -> Keeper_memory_os_types.fact list -> fit
