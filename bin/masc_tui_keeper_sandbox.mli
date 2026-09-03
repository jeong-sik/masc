(** Typed, terminal-safe projection of the Keeper status sandbox observation. *)

type t

val decode :
  sanitize:(string -> string) -> Yojson.Safe.t -> (t, string) result
(** Decode the [sandbox_live] block from [/api/v1/gate/keeper-status]. Missing
    observations stay missing; malformed observed fields fail closed. Every
    fetched string is passed through [sanitize] before it enters TUI state. *)

val view_lines : width:int -> t -> string list
(** Render an operator-facing status summary: whether commands can run, what
    happens next, configured resources and filesystem locations, then live
    CPU/memory/network facts when an instance exists. Internal projection
    names and server explanations are deliberately absent. Unobserved facts
    remain explicit rather than being inferred. [width] is the available
    content width, so long diagnostics wrap instead of disappearing at the
    pane edge.

    For a microvm keeper this also says where its build output lands: how
    many checkouts write to the block volume, and the path of each one still
    writing to the virtiofs share. That second list is the actionable half --
    a checkout on the share pins a host vnode per file it writes, and only a
    person can clear it, because the server refuses to delete build output it
    did not create. *)

type logs

val decode_logs :
  sanitize:(string -> string) -> Yojson.Safe.t -> (logs, string) result
(** Decode the authenticated host-runtime log response. Log payloads are split
    into lines before each line is terminal-sanitized. The three server states
    decode into distinct values: a backend with instances, a backend with
    none, and a Keeper whose profile keeps no stream on this host, which
    carries the server's sentence saying where the logs are. A state whose
    backend or instance list contradicts it is refused. *)

val logs_view_lines : width:int -> logs -> string list
(** Render the log pane for one Keeper, distinct from Keeper activity and
    tool-call history: Docker or Apple Container stdout/stderr when a local
    stream exists, and otherwise the sentence saying where the logs are.
    A Keeper with no local stream previously drew the red fetch-failure row;
    it now gets that sentence in the informational tone, and no backend name
    or tail count, because there is no stream for either to describe. *)
