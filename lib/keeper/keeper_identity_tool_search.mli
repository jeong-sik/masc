(** The attached-service surface, offered as a listing instead of as schemas.

    A Keeper attached to a work service is handed that service's entire tool
    list, and that list is charged to every provider request of the turn. One
    Keeper's list measured 145 tools and 142,257 bytes against 57 KB of
    built-in tools, 20% of it was called at all, and context overflow ended
    412 turns that day (RFC-attached-service-tool-scoping §1.5-1.6).

    So this offers one tool instead. Its description names every attached
    tool with a one-line summary, and calling it puts the named tools into
    the running agent's callable set, where the next provider request of the
    same turn carries their schemas.

    Distinct from {!Keeper_identity_tool_index}, which answers what an
    attached tool declared about itself for the approval policy. This one
    decides what the model is shown. *)

type surface =
  { offered : Keeper_identity_tools.offered_tool list
  ; agent_cell : Agent_core.Agent.t option ref
        (** The agent this turn is running, filled by [Runtime_agent.run] at
            agent creation -- which is before any tool of that agent can
            execute. The two fields travel in one record because attached
            tools without a cell are tools this can name and never make
            callable. *)
  }

val tool_name : string

(** What one turn got out of the listing. *)
type turn_discovery =
  | Listing_unused  (** The model never asked for a tool through it. *)
  | Loaded_and_used  (** It asked, and something it loaded then ran. *)
  | Loaded_unused of string list
      (** It asked, loaded these, and called none of them. Either the
          one-line summaries did not say enough to choose from, or the names
          it chose were not the ones it needed. *)

type placement =
  { tool : Agent_core.Tool.t  (** What the turn places. *)
  ; observe_turn : unit -> turn_discovery
        (** Call once when the turn ends, on both the ordinary and the raised
            path, and records {!Loaded_unused} where an operator can read it.

            Deferring the whole surface behind a name only works if the model
            finds what it needs through it, and {!Loaded_unused} is how that
            fails. Nothing else can see it: the durable tool-call rows name a
            tool but not where it came from, so "an attached tool ran this
            turn" is a question only the thing that built them can answer.
            {!Listing_unused} and {!Loaded_and_used} record nothing -- how
            often the listing is used at all is one [tool_calls] query away,
            and that is the denominator. *)
  }

val make
  :  keeper_name:string
  -> build:(Keeper_identity_tools.offered_tool -> Agent_core.Tool.t)
  -> surface
  -> placement option
(** The listing tool for one turn, or [None] when nothing is attached.

    [build] turns one offered tool into the tool that would have been placed
    in the turn directly -- for a Keeper that is the Gate wrapper. Every
    offered tool is built here and held; what changes is that the model is
    shown a name rather than a schema until it asks.

    Raises [Invalid_argument] if the argument schema this builds is refused,
    which can only be a defect in the literal it is built from. *)
