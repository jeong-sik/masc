(** RFC-0070 Phase 3b-iv.0 — Typed docker daemon response surface.

    Closed-variant transforms for the parts of [docker ps] /
    [docker inspect] output that callers need to branch on. Replaces
    F3 (RFC-0070 §1: substring parsing fragile to docker version
    drift) at the *type* level — the JSON-deserialisation layer that
    feeds these types arrives in Phase 3b-iv.1 (Mock) / 3b-iv.2 (Real).

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.3

    No I/O, no clock, no random. Pure value-level types. *)

(** {1 Container lifecycle state}

    Mirror of the [State] field returned by
    [docker ps --format '\{\{json .\}\}'] / [docker inspect].
    Docker's actual JSON emits one of the six string tokens enumerated
    below; we lift them into a closed sum so callers cannot drift on
    new docker versions without compiler help. *)

type ps_status =
  | Created
  | Running
  | Paused
  | Restarting
  | Exited of { code : int }
  | Dead
[@@deriving show, eq]

(** Parsing failures for [parse_state]. Closed sum — no catch-all. *)
type state_parse_error =
  | Unknown_state of string
      (** Docker emitted a state token we do not yet recognise. The
          payload carries the offending raw value for diagnostic. *)

(** [parse_state s] decodes a docker [State] string into the typed
    variant. Pure. The lowercase canonical forms are accepted
    case-insensitively. [Exited of { code }] requires the caller to
    supply [code] separately (docker exposes exit code via
    [ExitCode] / [docker inspect]). For Phase 3b-iv.0 the parser
    yields [Exited { code = 0 }] on the bare "exited" token; later
    phases extend the parser to consume the inspect record. *)
val parse_state : string -> (ps_status, state_parse_error) result

(** [state_to_string s] is the canonical lowercase token. Inverse of
    [parse_state] for non-Exited variants; Exited's exit code is not
    encoded in the state token (docker emits separately). *)
val state_to_string : ps_status -> string

(** {1 Exec result}

    What an executed [docker run] or [docker exec] returned to us.
    Distinct from {!ps_status}: this is per-call result, that is
    container-lifecycle state. *)

type exec_result =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }
[@@deriving show, eq]
