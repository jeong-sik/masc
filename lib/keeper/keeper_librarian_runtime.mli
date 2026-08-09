(** Runtime adapter for LLM-owned current Memory OS selection.

    A Librarian-owned research phase receives the complete Keeper model-visible
    tool bundle and records exact tool lifecycle evidence. The existing
    tool-free exact-output flow remains the sole selection authority and one
    atomic current-snapshot replacement remains the sole Memory OS mutation.
    If research or its RAW trace is unavailable, the exact flow continues from
    the original immutable Librarian input and records that degradation. *)

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

type research_context =
  { config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  ; ctx_snapshot : Keeper_types.working_context
  ; runtime_id : string
  ; continuation_channel : Keeper_continuation_channel.t option
  }

type extraction_error

(** Which failure kind this error records in the memory journal. The vocabulary
    is owned by {!Keeper_memory_os_current} because the journal is the only
    place it reaches disk; this function is the one place the classification
    happens, so adding an [extraction_error] case fails to compile until it
    names its journal kind. *)
val run_best_effort
  :  research_context:research_context
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
(** Execute a Librarian unit already admitted and fenced by the post-turn
    entrypoint. This runtime owns cadence, not the live configuration gate. *)
