(** What the approval policy needs to know about an attached service's tools.

    {!Keeper_tool_approval_policy} decides from what a tool declares, and a
    tool that came from somebody else's MCP server declares it there: the
    listing carries [annotations.readOnlyHint]. That answer arrives when a
    Keeper attaches, and the policy runs mid-turn with only a name in hand,
    so the two are joined here.

    The same shape {!Keeper_tool_composition_plan_index} uses for the same
    reason: the bundle builder writes it, the policy reads it. In memory,
    because it describes the tools this process handed out this turn -- a row
    that outlived the process would describe a Keeper nobody is running. *)

type t

val create : unit -> t

val shared : unit -> t
(** The instance the running process uses. *)

val record : t -> tool_name:string -> read_only:bool option -> unit
(** Declare what the service said about [tool_name].

    [read_only] is the service's own word: [Some true] only reads, [Some
    false] may write, [None] it did not say. All three are recorded as they
    are. Folding [None] into [Some false] here would lose the difference
    between a service that answered and one that did not, and the reason an
    operator reads is different for each. *)

val read_only : t -> tool_name:string -> bool option option
(** [Some answer] when this name was recorded, where [answer] is what the
    service said. [None] when it was never recorded, which for a caller means
    "not a tool from an attached service" rather than "a tool that may
    write". *)

val forget_all : t -> unit
(** Drop every row. For tests that need an empty index. *)
