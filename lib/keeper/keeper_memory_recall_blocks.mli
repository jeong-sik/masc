(** The two texts a judged turn adds to its context
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, section 4.4).

    The one call the context assembly makes, once per turn, before its first
    model request: it asks whether the Keeper is judged, reads the Keeper's
    facts, runs {!Keeper_memory_recall_turn.judge} on them and words the result
    with {!Keeper_memory_recall_render}. It only makes the texts. Putting them
    into a prompt is the caller's.

    {!prepare} uses Eio fibers and has to run inside an Eio main loop. *)

type t =
  { status : string
        (** The status line. Every judged turn has one, whatever the judgment
            came to. *)
  ; body : string option
        (** The memories the judgment carried; [None] when it carried none. *)
  }

val prompt_blocks : t -> (Prompt_block_id.t * string) list
(** The texts as prompt blocks: the status line as
    {!Prompt_block_id.Recalled_memory_status}, then the body, when there is
    one, as {!Prompt_block_id.Recalled_memory}. *)

val purpose :
  current_input:string -> keeper_instructions:string -> turn_ref:Ids.Turn_ref.t -> Yojson.Safe.t
(** What the judgment is for: this turn's input, the Keeper's instructions and
    the turn reference, as RFC section 4.2 starts it. The world frame is not
    in it. *)

val read_facts :
  keepers_dir:string -> keeper_id:string -> (Keeper_memory_os_types.fact list, string) result
(** The Keeper's current facts. A Keeper with no stored snapshot has none. This
    reads files and may complete a pending publication, so a caller on the main
    Eio domain runs it on the IO pool. *)

val prepare_with :
  judge:
    (Keeper_memory_recall_candidates.t list ->
     (Keeper_memory_recall_turn.t, Keeper_memory_recall_jev_codec.build_error) result) ->
  read_facts:(unit -> (Keeper_memory_os_types.fact list, string) result) ->
  keeper_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  memory_search_available:bool ->
  t option
(** {!prepare} with the judgment and the facts as parameters, so a test needs
    neither a network nor a store.

    Two gates come first. The kill switch of the older recall notice
    ({!Keeper_memory_os_recall.enabled}) is asked before anything else: with it
    off, the notice says recall is disabled and the Keeper gets no judged texts
    either. Then {!Typesafeai_config.memory_recall_destinations}: a Keeper that
    is not judged reads no facts, sends nothing and gets [None], so its turn is
    the one it had before the feature.

    [None] also when there is nothing to say: the Keeper has no facts, or a
    judgment was not made. Three causes are defects and are logged at warn
    instead of worded: the facts could not be read, a request could not be
    built (two facts with one id), and something raised. The turn goes on
    without the texts, because a failure here reaches the turn through the hook
    and would end it. A cancellation is the turn's own and is raised again. A
    Keeper whose facts cannot be read still gets the older recall notice, which
    reads the store itself and says when its own read fails.

    The facts are read once per call and the judgment may be one the turn
    kept from an earlier call, so the body is made from the facts of this call
    ({!Keeper_memory_recall_render.body} names an id whose fact is gone). *)

val prepare :
  memo:Keeper_memory_recall_turn.memo ->
  config:Workspace.config ->
  keepers_dir:string ->
  keeper_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  purpose:Yojson.Safe.t ->
  memory_search_available:bool ->
  t option
(** {!prepare_with} with {!read_facts} on the IO pool and
    {!Keeper_memory_recall_turn.judge}. The [memo] belongs to the turn and is
    passed to every call of it, a retry after a failover included.

    The time limit of a request comes from the clock of the Eio context
    ({!Eio_context.get_clock_opt}), because the client arms it only with a
    clock. With none, a judged Keeper gets [None] and a warning: a judgment
    without a limit could wait on a stalled destination until the turn's stall
    watchdog cuts the attempt. *)
