(** What a Keeper whose health is failing last failed at.

    The Keepers list keeps two readings apart: what the Keeper does now (its
    activity) and why its health is failing (this value). This module reads the
    second one from a roster row and does not look at the first. *)

(** The groups an operator acts on. Every constructor of
    [Keeper_request_failure.cause], and every constructor nested in its [Core]
    and [Masc] arms, maps to exactly one group, so a new constructor is a
    compile error here. *)
type cause_group =
  | Rate_limited  (** The provider throttled the request. *)
  | Connection  (** The transport to the runtime failed or closed. *)
  | Provider
      (** The provider or its API failed the call. Agent-core's [Api] and
          [Provider] categories land here whatever the status: the failure
          value carries the category and a message, and the message is not
          read, so a credential, billing, quota or server failure of those
          categories is in this group too. *)
  | Configuration  (** A setting or a registration has to change. *)
  | Input  (** The request did not fit the runtime's input capacity. *)
  | Unusable_reply  (** The runtime answered and MASC could not use the answer. *)
  | Effect_fenced
      (** An effect step failed and MASC closed the turn instead of replaying
          it. The effect may or may not have happened. *)
  | Recovery  (** A session, its transcript or a client needs a recovery step. *)
  | Stopped  (** A person or the host stopped the turn. *)
  | Server  (** The MASC server was not ready or restarted under the turn. *)
  | Internal  (** MASC or agent-core failed in a way no other group names. *)

(** What the last execution receipt says about the failed turn. A receipt is
    evidence for the turn that wrote it, and the server does not promise it is
    the turn the health reading judged. A value is taken from one receipt and
    is never mixed with another source. *)
type walk =
  | Walk_ended of { runtime_id : string; cause : cause_group; tried : int }
      (** The receipt names the runtime that ended the turn and why. [tried]
          counts the candidate runtimes the walk reached, once each, whether or
          not the request left MASC for the provider. It is at least 1. *)
  | Walk_no_terminal of { tried : int }
      (** The receipt records at least one candidate failure and no terminal
          one. [tried] is counted as for [Walk_ended] and is at least 1. *)
  | Walk_no_candidate_failure
      (** The receipt observed the candidate walk and recorded no candidate
          failure and no terminal one. An ordinary successful turn leaves this
          receipt, so it names no cause for the failure. *)
  | Walk_not_captured  (** The receipt exists and recorded no candidate walk. *)
  | Walk_unreadable  (** The receipt's walk evidence could not be read. *)
  | Walk_absent  (** The roster row carries no receipt. *)
  | Walk_not_applicable
      (** No receipt is read. The last failure is not a turn failure
          (heartbeat, fiber, exception, operator interrupt), or the roster row
          names no last failure. *)

type trail =
  | Trail_sound
  | Trail_failed of
      { ended_at : float option
            (** Unix time of the failure. It is the receipt's time for
                [Walk_ended] and [Walk_no_terminal], and the time the server
                reported with [last] for every other walk. [None] when that
                source gave none or the receipt's time does not parse. *)
      ; last : Masc.Tui_decode.keeper_failure_cause option
            (** The server's own closed cause word for the last failure. *)
      ; walk : walk
      }

val of_readings :
  health:Masc.Tui_decode.keeper_health option ->
  runtime:Masc.Tui_decode.keeper_runtime option ->
  trail
(** [Trail_failed] exactly when the health reading is failing. A health reading
    that is absent, healthy, idle or offline gives [Trail_sound]. *)

type attempt =
  { ordinal : int
  ; runtime_id : string
  ; dispatch : Runtime_attempt_dispatch.t option
  ; cause : cause_group
  ; fault : string option
  ; terminal : bool
  }

val attempts_of_runtime :
  Masc.Tui_decode.keeper_runtime option ->
  attempt list
(** Ordered candidate and terminal attempts recorded in the last execution
    receipt for a failing turn. Returns an empty list when the last failure is
    sound or not a turn failure. The number of attempts matches the candidate
    count reported in [Walk_ended] or [Walk_no_terminal]. The terminal attempt
    takes its cause from the terminal error and keeps the dispatch and the API
    fact of the candidate failure recorded for the same ordinal. *)

(** The next-head fact is independent of a failure in the last walk. *)
type matrix_head = Head_elsewhere | Head_serving | Head_resting | Head_unknown

type matrix_failure = Matrix_failed | Matrix_clear | Matrix_unknown

type matrix_cell = { failure : matrix_failure; head : matrix_head }

val matrix_cell : runtime_id:string -> Masc.Tui_decode.keeper_runtime option -> matrix_cell
(** Exact runtime identity membership in {!attempts_of_runtime}, alongside
    the producer's typed next path. An unread path stays [Head_unknown]; the
    current runtime id is never substituted for an unknown next head. A
    missing/unread/not-applicable walk is [Matrix_unknown], never clear. *)

val matrix_runtime_ids : Masc.Tui_decode.keeper_runtime option -> string list
(** Distinct runtime identities in the last failed walk and the observed next
    path. No identities are inferred from labels or from the current runtime. *)
