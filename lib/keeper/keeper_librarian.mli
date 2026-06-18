(** Keeper_librarian — structured claim extraction for the Memory OS.

    This module stays on the MASC side of the OAS boundary. It does not call
    providers or persist files; callers choose the message slice, render the
    external prompt, call the LLM, and store accepted episodes via
    [Keeper_memory_os_io]. *)

(** Input bundle for one librarian extraction. *)
type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  }

(** Prompt variables for [keeper.librarian.episode_extraction]. *)
val prompt_variables : input -> (string * string) list

(** Parse a raw strict-JSON LLM response into an episode.

    [None] means the response was not JSON or violated the extraction schema.
    [now] is optional so tests can keep timestamps deterministic. *)
val episode_of_output
  :  ?now:float
  -> ?generation:int
  -> input
  -> string
  -> Keeper_memory_os_types.episode option

(** Scrub private runtime markers from messages before prompt rendering. *)
val scrub_messages_for_librarian
  :  Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list
