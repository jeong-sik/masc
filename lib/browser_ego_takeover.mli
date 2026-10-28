(** Native takeover of the already bound Space after explicit operator
    completion. This does not claim a user-owned Space or adopt a Page. *)
val script : string
(** Fixed body for the peer's Operator_holds frame. [args.spaceId] is supplied
    by the peer, never by browser tool input. The original numeric ID is
    checked before takeover. Native userPage identity is captured before
    reconciling that same Space's tabs; no Page document methods are called.
    An absent boundary Page stays absent, with no current-active fallback. *)
type t = { space : Browser_lane.ego_space; page : Browser_surface.ego_page option }
val decode : expected_id:int -> Yojson.Safe.t -> (t, string) result
(** Strict native receipt. [page=None] means the SDK captured no user Page,
    not an unreadable or missing target. A managed or unmanaged Page retains
    its exact target/origin; observations grant no adoption or mutation rights.
    A malformed post-takeover receipt is an uncertain effect, never replay
    permission. The name is metadata and may differ after a rename. *)
