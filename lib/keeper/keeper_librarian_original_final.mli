(** Host proof of an original's final, for every original request that asks a
    configured declaration's Exact output flow. The completed-history range
    request and the message-floor step request each build their own request and
    check their own physical owner; what the host retained for that request is
    read here once. Blocking store reads: offload the whole call from Eio. *)
type target
val target : installation_id:string -> Lane_addon_exact.request -> (target, string) result
(** The request, the schema it carries and the configured declaration that
    retains it. A request without a schema and a manual installation are errors. *)
val refusal_evidence : store:Lane_addon_store.t -> target:(unit -> (target, string) result) ->
  Lane_addon_exact.final -> (Keeper_exact_walk_failure.t, string) result
(** What a final shows about reading less. Only an [Input_refused] final naming
    a request body, input capacity or context refusal can show it, and only then
    is [target] called; [Invalid_request] and every other final show nothing. With no host record, the worker's frame refusal
    ([Lane_addon_exact.refused_before_host]) is itself the evidence. With a host
    terminal, the latest completed execution must end in this same final, and
    its receipt supplies the walk's evidence, and only when that evidence is a
    named input refusal with no independent failure mixed in. Anything else,
    including an open host record, shows nothing. *)
val confirm_final : store:Lane_addon_store.t -> target -> Lane_addon_exact.final ->
  (unit, string) result
(** Require the original retained host terminal. Each Call_final additionally
    requires the matching latest completed original execution proof and outcome.
    Worker Finished JSON grants nothing, except a final where
    {!Lane_addon_exact.refused_before_host} holds, for a request the host never
    retained: the worker refuses a request no listing reply can carry before the
    host sees it, and that final holds no answer. *)

val decode_final : store:Lane_addon_store.t -> target -> Yojson.Safe.t ->
  (Lane_addon_exact.final, string) result
(** Strictly decode the final when possible. If a consumer-schema answer is
    rejected by the strict decoder, recover it only from the matching original
    host terminal and latest execution proof, without changing the JSON. This
    is not domain validation, delivery authority, or permission to write. The
    caller still validates the final and original domain proposal. Blocking
    Store reads must be offloaded from Eio. *)
