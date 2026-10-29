(** The recall judgment of one turn
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, sections 4.6 and 4.7).

    The one entry the context assembly calls. It asks whether the keeper is
    judged at all, runs {!Keeper_memory_recall_flow} through the evaluation
    record, counts the outcome, and gives the same judgment back for the rest
    of its turn.

    A Keeper runs one turn at a time and a turn judges once, before its first
    model request, so one Keeper has one judgment in flight.

    {!judge} uses Eio fibers and has to run inside an Eio main loop. *)

type t =
  | Off of Typesafeai_config.unavailable_reason
      (** The keeper is not judged: the switch is off, the keeper is outside
          its scope or excluded, or the lane cannot be reached. Nothing was
          sent or saved, and the turn has no status line. *)
  | Nothing_to_judge
      (** The keeper has no candidate. Nothing was sent or saved. *)
  | Judged of Keeper_memory_recall_flow.judged
      (** The judgment to use. Its outcome row is saved: when that failed, it
          is {!Keeper_memory_recall_flow.not_recorded}. *)

(** The judgment kept for one turn of one keeper. The context assembly creates
    it when the turn starts and passes it to every call of that turn, a retry
    after a failover included. The turn owns it, so nothing outlives the turn
    and no keeper can read another's. *)
type memo

val create_memo : unit -> memo

val judge_with :
  evaluate:
    (Keeper_memory_recall_evaluation.t -> Keeper_memory_recall_flow.evaluate) ->
  memo:memo ->
  config:Workspace.config ->
  keeper_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  purpose:Yojson.Safe.t ->
  Keeper_memory_recall_candidates.t list ->
  (t, Keeper_memory_recall_jev_codec.build_error) result
(** {!judge} with the way a request is evaluated as a parameter, so a test
    needs no network. [Error] is the flow's: a request cannot be built (two
    candidates share an id, or an option set is invalid), so nothing was sent.
    That is a defect of the caller's candidates.

    The gate comes first: {!Typesafeai_config.memory_recall_destinations}
    decides whether the keeper is judged, at every call, so a switch turned
    off during a turn stops the next call.

    A judgment whose status is not [unavailable] is kept in the [memo] under
    its [turn_ref]. The next call with the same [memo] and [turn_ref] gives it
    back without sending anything, whatever [purpose] and candidates it
    carries, and is not counted again. A call with another [turn_ref] judges
    again and replaces it: the memo holds one judgment. A judgment that came to
    [unavailable] is not kept, so a retry within the turn asks again. A
    cancellation raised from the flow builds no judgment, keeps nothing and
    counts nothing.

    Every judgment is counted once it is complete:
    [masc_keeper_memory_recall_total] by keeper and outcome (the status token),
    [masc_keeper_memory_recall_selected_total] by keeper for the candidates it
    carried, and [masc_keeper_memory_recall_judgment_seconds] by keeper from
    the first request to the saved outcome. *)

val judge :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  memo:memo ->
  config:Workspace.config ->
  keeper_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  purpose:Yojson.Safe.t ->
  Keeper_memory_recall_candidates.t list ->
  (t, Keeper_memory_recall_jev_codec.build_error) result
(** {!judge_with} with {!Keeper_memory_recall_evaluation.evaluate}: requests
    go to the destinations the gate named, each with the client's own time
    limit. The client arms that limit only with a [clock], so the clock is
    required. No time limit is added around the judgment as a whole. *)
