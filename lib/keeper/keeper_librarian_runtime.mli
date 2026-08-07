(** Runtime adapter for LLM-owned current Memory OS selection.

    One OAS exact-output call selects the complete current memory. After domain
    validation, one atomic current-snapshot replacement is the only MASC-side
    effect. There is no secondary journal or episode/facts fan-out. *)

val cadence_step : cadence:int -> counter:int -> int * bool
val cadence_step_keyed
  :  cadence:int
  -> current_trace:string
  -> prior:(string * int) option
  -> (string * int) * bool
val cadence_counter_entries : unit -> int

val max_messages : unit -> int
val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

type extraction_error

(** Which failure kind this error records in the memory journal. The vocabulary
    is owned by {!Keeper_memory_os_current} because the journal is the only
    place it reaches disk; this function is the one place the classification
    happens, so adding an [extraction_error] case fails to compile until it
    names its journal kind. *)
val run_best_effort
  :  keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
(** Execute a Librarian unit already admitted and fenced by the post-turn
    entrypoint. This runtime owns cadence, not the live configuration gate. *)
