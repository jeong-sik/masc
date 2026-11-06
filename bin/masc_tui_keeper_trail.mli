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
  | Provider  (** The provider or its API failed the call. *)
  | Configuration  (** A setting, a credential or a registration has to change. *)
  | Input  (** The request was too large for the runtime. *)
  | Unusable_reply  (** The runtime answered and MASC could not use the answer. *)
  | Effect_fenced
      (** An effect may have happened, so the turn was closed and not replayed. *)
  | Recovery  (** A session or a client needs a recovery step. *)
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
          counts the candidate runtimes the receipt recorded. *)
  | Walk_no_terminal of { tried : int }
      (** The receipt records candidate failures and no terminal one. *)
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
(** [Trail_failed] exactly when the health reading is failing. *)
