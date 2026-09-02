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
