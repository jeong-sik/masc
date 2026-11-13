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
    is [target] called; [Invalid_request] and every other final show nothing. With no host record, the worker's frame refusal
    ([Lane_addon_exact.refused_before_host]) is itself the evidence. With a host
    terminal, the latest completed execution must end in this same final, and
    its receipt supplies the walk's evidence, and only when that evidence is a
    named input refusal with no independent failure mixed in. Anything else,
    including an open host record, shows nothing. *)
type unconfirmed = Terminal_absent | Terminal_unresolved | Terminal_differs
  | Latest_incomplete | Latest_ordinal_invalid | Latest_differs | Latest_refused
(** Why the host evidence does not confirm a final. Each consumer words its
    own error for it. *)
type verdict = Confirmed | Unconfirmed of unconfirmed

val confirm : observe:(unit -> (Lane_addon_exact.retained_observation, string) result) ->
  latest:(unit -> (Lane_addon_exact.latest_original_execution, string) result) ->
  Lane_addon_exact.final -> (verdict, string) result
(** The rule every original consumer confirms a final with, and the deploy
    check judges an original's Exact files with. [observe] reads the original's
    Exact record. Without one, only a final where
    {!Lane_addon_exact.refused_before_host} holds is confirmed. An open record
    confirms nothing. A terminal must deliver this final, and a [Call_final]
    then also needs the latest completed execution to have ended in it:
    [latest] reads that execution and is called for nothing else. [Error] is
    a read or canonical JSON failure. Reads only through [observe] and
    [latest]. *)

val unconfirmed_detail : unconfirmed -> string
(** The error {!confirm_final} returns for each reason. *)

val confirm_final : store:Lane_addon_store.t -> target -> Lane_addon_exact.final ->
  (unit, string) result
(** Require the original retained host terminal. Each Call_final additionally
    requires the matching latest completed original execution proof and outcome.
    Worker Finished JSON grants nothing, except a final where
    {!Lane_addon_exact.refused_before_host} holds, for a request the host never
    retained: the worker refuses a request no listing reply can carry before the
    host sees it, and that final holds no answer. *)

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
