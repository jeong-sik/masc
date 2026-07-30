(** Runtime adapter for LLM-owned current Memory OS selection.

    One OAS exact-output call selects the complete current memory. After domain
    validation, one atomic current-snapshot replacement is the only MASC-side
    effect. There is no secondary journal or episode/facts fan-out. *)

val enabled : unit -> bool
val cadence_turns : unit -> int

val cadence_step : cadence:int -> counter:int -> int * bool
val cadence_step_keyed
  :  cadence:int
  -> current_trace:string
  -> prior:(string * int) option
  -> (string * int) * bool
val cadence_due : keeper_id:string -> trace_id:string -> bool
val cadence_record_success : keeper_id:string -> trace_id:string -> unit
val cadence_record_attempt : keeper_id:string -> trace_id:string -> unit
val cadence_counter_entries : unit -> int

val max_messages : unit -> int
val select_recent_messages
  :  max_messages:int
  -> Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val exact_lane_id : string

type extraction_error

type extraction_error_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_snapshot_write_failure

val extraction_error_kind : extraction_error -> extraction_error_kind
val extraction_error_to_string : extraction_error -> string
val should_record_cadence_backoff_after_error : extraction_error -> bool

val extract_with_exact_output_classified
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> Keeper_librarian.input
  -> (Keeper_librarian.selection, extraction_error) result

val extract_and_commit_with_exact_output_classified
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> (Keeper_memory_os_current.t, extraction_error) result

val run_best_effort
  :  keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
