(** Mermaid rendering of the turn FSM, derived from the FSM itself. *)

val edges : unit -> (string * string * string) list
(** Every transition the FSM admits, as [(from_symbol, to_symbol, label)] in
    {!Turn_fsm.all_states} order. Produced by asking
    {!Turn_fsm.classify_transition} about each ordered pair, so a transition
    arm added or removed changes this list with nothing else to update. The
    label is the action name, and for an edge into a state that carries a
    reason it names the reason too -- the FSM admits a separate edge per
    reason, and without it three lines into [Failed] read identically. *)

val node_symbols : unit -> string list
(** The distinct state symbols, sorted. One per state the FSM can hold, not
    one per reason: [Failed] is a single node whatever failed. *)

val diagram : ?current:string -> unit -> string
(** A Mermaid [stateDiagram-v2] of the whole machine.

    [current] marks the state the reader is standing in, matched against the
    symbol ([Turn_fsm.to_tla_symbol]), not the label -- a label carries the
    reason and would never match a caller holding "Streaming". A name that
    is not a state highlights nothing rather than adding a node for it. *)
