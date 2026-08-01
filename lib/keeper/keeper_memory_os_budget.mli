(** Byte-budget contract for the dynamic Memory OS fact payload.

    The measured bytes are exactly the UTF-8 bytes that recall places in the
    [facts] template variable: identity, category, claim, separators, and line
    breaks. Prompt-template boilerplate is deliberately outside this policy. *)

type measurement =
  { actual_bytes : int
  ; max_bytes : int
  }

type fit =
  | Fits of measurement
  | Exceeds of measurement

val render_facts : Keeper_memory_os_types.fact list -> string
val measure : max_bytes:int -> Keeper_memory_os_types.fact list -> fit
