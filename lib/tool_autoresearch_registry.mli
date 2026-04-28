(** Tool_autoresearch_registry — loop registry, pending hypothesis
    queue, and per-loop code-generator override state for the
    autoresearch loop.

    Two of the three Hashtbls ([pending_hypotheses],
    [custom_generators]) are reached into by the dashboard HTTP
    handler ([Hashtbl.remove] on cancellation) and by the test
    suite ([Hashtbl.reset] between cases), so they are exposed
    by the .mli rather than wrapped in accessor functions —
    pretending they were private would force every caller into
    awkward setter/getter pairs without making the storage any
    more abstract.

    [active_loops] / [latest_loop_id] are re-exports of the
    {!Autoresearch} state slot so [Tool_autoresearch] (which does
    [include Tool_autoresearch_registry]) and
    [Tool_autoresearch_cycle] (which does
    [open Tool_autoresearch_registry]) can share a single name. *)

val active_loops : (string, Autoresearch.loop_state) Hashtbl.t
(** Re-export of [Autoresearch.active_loops]. The dashboard's
    cancellation handler and the cycle runner both mutate this
    table directly. *)

val latest_loop_id : string option ref
(** Re-export of [Autoresearch.latest_loop_id]. The dashboard
    sets this on loop start; consumers read it for the "most
    recent loop" UI affordance. *)

val pending_hypotheses : (string, string) Hashtbl.t
(** Per-loop queue of operator-injected hypotheses awaiting the
    next cycle. Keys are loop ids; values are the hypothesis
    text. The dashboard's cancellation handler clears entries
    via [Hashtbl.remove]; the test suite resets the table
    between cases. *)

(** Per-loop code generator type used by tests to inject a
    deterministic stand-in for [Autoresearch.generate_code_change].
    Returns either [Ok (hypothesis, new_code)] or [Error reason]. *)
type code_generator =
  goal:string ->
  baseline:float ->
  lower_is_better:bool ->
  history:Autoresearch.cycle_record list ->
  insights:string list ->
  target_file:string ->
  file_content:string ->
  (string * string, string) result

val custom_generators : (string, code_generator) Hashtbl.t
(** Per-loop override table. The dashboard's cancellation handler
    clears entries via [Hashtbl.remove]; the test suite resets
    the table between cases. *)

val set_generator : string -> code_generator -> unit
(** Install a custom generator for [loop_id] (last-writer-wins
    via [Hashtbl.replace]). Used in tests to inject deterministic
    behaviour. *)

val get_generator : string -> code_generator
(** Resolve the generator for [loop_id]; falls back to
    [Autoresearch.generate_code_change] when no override is
    registered. *)
