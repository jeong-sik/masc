(** Host proof of an original's final, for every original request that asks a
    configured declaration's Exact output flow. The completed-history range
    request and the message-floor step request each build their own request and
    check their own physical owner; what the host retained for that request is
    read here once. Blocking store reads: offload the whole call from Eio. *)
type target = private
  { exact : Lane_addon_exact.request
  ; schema : Yojson.Safe.t
  ; declaration_id : string
  }
val target : installation_id:string -> Lane_addon_exact.request -> (target, string) result
(** The request, the schema it carries and the configured declaration that
    retains it. A request without a schema and a manual installation are errors. *)
val refusal_evidence : store:Lane_addon_store.t -> target:(unit -> (target, string) result) ->
  Lane_addon_exact.final -> (Keeper_exact_walk_failure.t, string) result
(** What a final shows about reading less. Only an [Input_refused] final naming
    a request body, input capacity or context refusal can show it, and only then
    is [target] called; [Invalid_request] and every other final show nothing.
    With no host record, the worker's frame refusal
    ([Lane_addon_exact.refused_before_host]) also requires the actual reader to
    confirm execution proof absence. Orphan or unreadable proof refuses.
    With a host terminal, the latest completed execution must end in this same final, and
    its receipt supplies the walk's evidence, and only when that evidence is a
    named input refusal with no independent failure mixed in. Anything else,
    including an open host record, shows nothing. *)
type unconfirmed = Terminal_absent | Terminal_unresolved | Terminal_differs
  | Latest_incomplete | Latest_ordinal_invalid | Latest_differs | Latest_refused
(** Why the host evidence does not confirm a final. Each consumer words its
    own error for it. *)
type verdict = Confirmed | Unconfirmed of unconfirmed

val require_declaration_ending_latest : Lane_addon_exact.latest_original_execution -> (unit, string) result
(** Pure closed check after an actual typed declaration-ending terminal and
    a strict latest-execution read. No completed latest attempt or a bound
    [Call_refused] from an earlier closed deferral is compatible with that
    ending. A [Call_ended] is not. This grants no live ending, retry or effect
    authority and must not be used for Cut release. *)

val declaration_replaced : store:Lane_addon_store.t -> target -> Lane_addon_tool_request_owner.retained ->
  (bool, string) result
(** Bind an execution refusal's typed cause to the original host Exact record.
    Current worker availability cannot revoke this past no-send verdict.
    Independently read the actual latest execution, validating all retained
    proofs even when a retained Rejected skips submit recovery. An earlier
    bound [Call_refused] deferral is compatible with the ending; a completed
    call result, malformed, unreadable or contradictory proof is not. This
    does not claim that no earlier provider attempt occurred. The caller must first bind the
    original and confirm its final. Blocking Store reads must be offloaded
    from Eio. *)

val confirm : observe:(unit -> (Lane_addon_exact.retained_observation, string) result) ->
  latest:(unit -> (Lane_addon_exact.latest_original_execution, string) result) ->
  Lane_addon_exact.final -> (verdict, string) result
(** The rule every original consumer confirms a final with, and the deploy
    check judges an original's Exact files with. [observe] reads the original's
    Exact record. Without one, only a final where
    {!Lane_addon_exact.refused_before_host} holds and [latest] reports no
    completed execution can be confirmed. Its store reader must reject an
    orphan or unreadable proof. An open record
    confirms nothing. A terminal must deliver this final, and a [Call_final]
    then also needs the latest completed execution to have ended in it:
    [latest] reads that execution and checks the no-host frame exception.
    Independently, an actual retained typed
    declaration-ending cause requires the strict latest read and
    {!require_declaration_ending_latest}, even when the worker's delivered
    Not_allowed JSON carries only its public detail. Worker wording does not
    establish that typed cause. [Error] is
    a failed read, an incompatible proof or a canonical JSON failure. Reads only through [observe] and
    [latest]. *)

val unconfirmed_detail : unconfirmed -> string
(** The error {!confirm_final} returns for each reason. *)

val confirm_final : store:Lane_addon_store.t -> target -> Lane_addon_exact.final ->
  (unit, string) result
(** Require the original retained host terminal. Each Call_final additionally
    requires the matching latest completed original execution proof and outcome.
    An actual typed declaration ending also requires the strict latest-proof
    check above before any consumer may treat its original as settled.
    Worker Finished JSON grants nothing, except a final where
    {!Lane_addon_exact.refused_before_host} holds, with both the host record
    and execution proof absent: the worker
    refuses a request no listing reply can carry before the host sees it, and
    that final holds no answer. Orphan or unreadable proof refuses. *)

val decode : schema:Yojson.Safe.t ->
  observe:(unit -> (Lane_addon_exact.retained_observation, string) result) ->
  confirm:(Lane_addon_exact.final -> (unit, string) result) ->
  Yojson.Safe.t -> (Lane_addon_exact.final, string) result
(** The final a judgment names, as {!decode_final} finds it and the deploy
    check finds it in files. The strict decoder answers first. When it refuses,
    the judgment names the original's Answered terminal if the record holds one
    that delivers exactly this JSON, and that final must pass [confirm]. A
    record without an Answered terminal leaves the strict decoder's error, and
    one that delivers other JSON is an error. [observe] reads the original's
    Exact record only after the strict decoder refuses. Reads only through
    [observe] and [confirm]. *)

val decode_final : store:Lane_addon_store.t -> target -> Yojson.Safe.t ->
  (Lane_addon_exact.final, string) result
(** Strictly decode the final when possible. If a consumer-schema answer is
    rejected by the strict decoder, recover it only from the matching original
    host terminal and latest execution proof, without changing the JSON. This
    is not domain validation, delivery authority, or permission to write. The
    caller still validates the final and original domain proposal. Blocking
    Store reads must be offloaded from Eio. *)
