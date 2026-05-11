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

(** Six closed states from docker's [State] field.

    Exit code is NOT carried here. The [State] token alone does not
    convey [ExitCode]; that field arrives via [docker inspect].
    Phase 3b-iv.2 will introduce a separate [inspect_record] type
    that pairs [ps_status] with the inspect-only fields
    ([ExitCode], [StartedAt], [FinishedAt], ...). *)
type ps_status =
  | Created
  | Running
  | Paused
  | Restarting
  | Exited
  | Dead
[@@deriving show, eq]

(** Parsing failures for [parse_state]. Closed sum — no catch-all. *)
type state_parse_error =
  | Unknown_state of string
      (** Docker emitted a state token we do not yet recognise. The
          payload carries the offending raw value for diagnostic. *)

(** [parse_state s] decodes a docker [State] string into the typed
    variant. Pure. The lowercase canonical forms are accepted
    case-insensitively. The function inspects only the [State] token,
    so it returns [Exited] without an exit code — callers that need
    [ExitCode] must consume the inspect record separately (Phase
    3b-iv.2). *)
val parse_state : string -> (ps_status, state_parse_error) result

(** [state_to_string s] is the canonical lowercase token. Round-trips
    through [parse_state] for every variant (no per-variant payload). *)
val state_to_string : ps_status -> string

(** {1 Exec result}

    [exec_result] is the *per-call result* of an executed [docker run]
    or [docker exec] — exit code plus captured streams. This is
    distinct from {!ps_status}, which describes the
    *container lifecycle state* over time. The two answer different
    questions: "did this call succeed?" vs "is this container alive?". *)

type exec_result =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }
[@@deriving show, eq]

(** {1 Container snapshot ([docker ps] row)} *)

(** A row from [docker ps --format '\{\{json .\}\}']. The fields are
    *exactly* what cleanup / quarantine logic in Phase 3b-iv.3 needs to
    branch on; richer per-container metadata stays in
    [docker inspect]'s separate response surface (introduced in Phase
    3b-iv.2 alongside [Docker_client.Real]).

    [labels] is the parsed label dictionary. Docker's wire format emits
    a single comma-separated string ("k1=v1,k2=v2"); the parser splits
    it before constructing the record so callers see structured data,
    not the raw string. *)
type ps_record =
  { id : string
  ; name : Keeper_container_name.t
  ; status : ps_status
  ; labels : (string * string) list
  }
[@@deriving show, eq]
