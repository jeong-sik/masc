(** Env-var parsing helpers for the keeper memory bank. *)

val memory_env_opt : string -> string option
val memory_env_int_logged : string -> default:int -> int
val memory_env_float_logged : string -> default:float -> float
val memory_env_bool_logged : string -> default:bool -> bool
val memory_llm_summary_enabled : unit -> bool
val max_memory_text_length : unit -> int

(* RFC keeper-memory-consolidation Stage 1: memory_bank long-term inject
   kill-switch (MASC_KEEPER_BANK_LONGTERM_INJECT, default=true). *)
val bank_longterm_inject_enabled : unit -> bool
