(** Durable record of one recall judgment
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, section 4.6) and the edge
    between the recall flow and the TypeSafe client.

    The flow asks questions through {!Keeper_memory_recall_flow.evaluate}.
    {!evaluate} is that function for one judgment: it saves the request before
    the client is called and the response before the flow sees it, and maps the
    client's failure to {!Keeper_memory_recall_flow.attempt_failure}. A request
    or a response that cannot be saved is not used: the flow gets
    [Not_recorded] and the request is not sent, or the response is dropped.

    One {!t} is one judgment, and its rows go to one file, private to the
    Keeper: [memory-recall-evaluations.jsonl] in the Keeper's runtime
    directory. The file may be over its size limit by one judgment. It is
    rotated when it is at the limit, before the first row of the next
    judgment, so a judgment never splits across two files. The limit and the
    number of kept files are those of the other Keeper logs
    ([MASC_KEEPER_METRICS_MAX_BYTES], [MASC_KEEPER_METRICS_MAX_ROTATED]).

    A Keeper runs one turn at a time and a turn makes one judgment, so one
    file has one judgment writing to it. Two judgments of one Keeper at once
    would lose no row, but their rotations could overlap and lose an old file.

    Rows contain private Keeper memory and sanitized destination identities.
    Credentials are never written.

    Each request is counted by Keeper, question kind and result
    ([masc_keeper_memory_recall_requests_total]) and timed from the call to its
    result ([masc_keeper_memory_recall_request_seconds]). The size of its
    [started] row, the state and the questions with the identity fields, is
    added to [masc_keeper_memory_recall_input_bytes_total]. That is the size of
    the record, not of the body on the wire.

    The functions that write run inside an Eio main loop: the first row of a
    judgment forces the rotation inside a protected section. *)

type t

val create :
  config:Workspace.config ->
  keeper_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  destinations:Typesafeai_config.destinations ->
  t
(** The caller resolves the enabled destinations and the Keeper exclusions
    first. Nothing is read or written yet. *)

val journal_path : t -> string
(** Private evidence path; not a model-facing retrieval route. *)

val judgment_id : t -> string
(** The identity every row of this judgment carries, next to the [turn_ref]. *)

val attempt_failure_of_client_failure :
  Typesafeai_client.failure -> Keeper_memory_recall_flow.attempt_failure
(** [Capacity_refused] when the client takes the failure for a capacity refusal
    (every destination answered 400 with the exact protocol code).
    Otherwise [Rate_limited] when every destination answered HTTP 429,
    [Invalid_response] when every destination answered HTTP 200 with a body
    that does not decode, and [Failed] for everything else: a transport
    failure, a timeout, any other status, or a mix. This is the rule the
    client uses for capacity, applied to the other two. *)

val evaluate :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  t ->
  Keeper_memory_recall_flow.evaluate
(** Called from several fibers at the same time, one call for each request.
    Each call writes its own rows in this order: [started] with the exact
    state and questions, then [response_received] or [provider_failed], or
    [cancelled] when the call is cancelled. Every row carries the [judgment_id],
    the [turn_ref], the [request_id] and the [kind] of the question. The
    cancellation is raised again once its row is saved, when it can be.

    A request is closed when a row with another status than [started] carries
    its [request_id]. An exception that is not a cancellation, which the client
    does not raise, is raised again and leaves its request open. *)

val evaluate_with :
  call:
    (destinations:Typesafeai_config.destinations ->
     state:Yojson.Safe.t ->
     questions:(string * Typesafeai_types.question) list ->
     unit ->
     (Typesafeai_client.evaluated, Typesafeai_client.failure) result) ->
  t ->
  Keeper_memory_recall_flow.evaluate
(** {!evaluate} with the client call as a parameter, so a test needs no
    network. *)

val retain_outcome :
  t -> Keeper_memory_recall_flow.judged -> Keeper_memory_recall_flow.judged
(** Saves the final row of the judgment ([judgment_completed]): the status and
    its coverage and reason, the selected ids, the answer of question (b), the
    result of every candidate and the mark of every carried candidate. Returns
    the judgment to use. When the row cannot be saved that is
    {!Keeper_memory_recall_flow.not_recorded}, so a judgment is used only when
    its record exists. *)
