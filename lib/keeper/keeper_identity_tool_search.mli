(** Tools the model is shown by name until it asks for the argument schema.

    A tool surface is charged to every provider request of a turn, and a turn
    is many requests -- 83 on one measured turn. Two things make that surface
    large. A Keeper attached to a work service is handed that service's entire
    tool list: one Keeper's was 145 tools and 142,257 bytes against 57 KB of
    built-ins, 20% of it was called at all, and context overflow ended 412
    turns that day (RFC-attached-service-tool-scoping §1.5-1.6). And the
    built-ins themselves accumulate: of 89 on one Keeper, 33 went a whole day
    without being called, 21,601 bytes of every request.

    So the schemas are held back and one tool is offered instead. Its
    description carries the held tools' names and nothing else, and calling
    it with exact names puts those tools into the running agent's callable
    set, where the next request of the same turn carries their schemas.

    Names only because the listing is charged to every request: with one
    summary line per tool it was 6 to 9 KB on the Keepers measured
    2026-09-02, 7 to 14% of the whole tool surface. The summaries now travel
    in the answer to a load, once. Nothing here reads the descriptions: a
    tool is chosen by its declared name and by nothing else, so editing a
    tool's prose cannot change what a request loads.

    What is held back is a property of the tool, not of where it came from. An
    attached tool is held by default; a built-in is held when its own
    [config/tools/<name>.toml] declares [defer_loading = true]. Grouping by
    source is what this replaced -- and grouping by Keeper is what PR #31728
    removed before that.

    Distinct from {!Keeper_identity_tool_index}, which answers what an
    attached tool declared about itself for the approval policy. This one
    decides what the model is shown. *)

(** One tool the model is shown by name until it asks for the schema. *)
type deferred =
  { tool : Agent_core.Tool.t
        (** What runs once the model has asked for it. Already wrapped by
            whatever the turn wraps its tools in -- the Gate, for an attached
            service -- so this places what the turn would have placed. *)
  ; summary : string
        (** The one line the listing shows beside the name. *)
  }

type surface =
  { deferred : deferred list
        (** Every tool held back from the request. Attached-service tools by
            default, since a Keeper is handed its services' entire lists; a
            built-in when its own [config/tools/<name>.toml] says
            [defer_loading = true]. The listing does not distinguish them, and
            neither does the model: what is deferred is a property of each
            tool, not of where it came from. *)
  ; agent_cell : Agent_core.Agent.t option ref
        (** The agent this turn is running, filled by [Runtime_agent.run] at
            agent creation -- which is before any tool of that agent can
            execute. The fields travel in one record because deferred tools
            without a cell are tools this can name and never make callable. *)
  ; history : Agent_core.Types.message list
        (** The conversation this turn continues, read for {!already_used}. *)
  ; carry_window : int
        (** How far back through the conversation a tool's last call may be
            and still be placed with its schema, counted in [ToolUse] blocks
            of any tool. [0] or less places every tool this conversation has
            ever run; the caller sets this field, and the runtime param behind
            it is clamped at [0], so a negative value is a caller defect and
            is treated as off rather than as a window of its own.

            Not a continuous bound. The carry is measured against this window
            only on a call to a tool the carry does not already hold, because
            that is the call that changes the tool array and so forfeits the
            provider's cache prefix anyway ({!already_used}). Between two such
            calls the set is frozen, so a tool can sit further back than this
            and still be placed. A Keeper that keeps re-using the tools it
            already carries stops evicting until it reaches for one it does
            not.

            Counted in tool calls rather than turns because that is the same
            evidence {!already_used} reads, so no turn boundary has to be
            recovered from a flat message list, and because a built-in call
            fills the conversation the same way an attached one does.

            Set by the caller rather than read from configuration here: two
            turns built from the same history must place the same tools, and a
            window this module fetched for itself would make that depend on
            when it was fetched. *)
  }

val summary_of : string -> string
(** The one line the answer shows beside a tool it loaded, cut from the
    tool's description.

    Exposed because the caller builds the {!deferred} records: what a tool
    costs in the listing is the same however it came to be deferred, and two
    ways of cutting it would be two listings' worth of drift. Cuts on a
    character boundary, so a multi-byte character is never split. *)

val tool_name : string

val names_param : string
(** The argument that names tools exactly. *)

(** What one turn got out of the listing. *)
type turn_discovery =
  | Listing_unused  (** The model never asked for a tool through it. *)
  | Loaded_and_used  (** It asked, and something it loaded then ran. *)
  | Loaded_unused of string list
      (** It asked, loaded these, and called none of them. Either the names
          in the listing did not say enough to choose from, or the names it
          chose were not the ones it needed. *)

type placement =
  { tool : Agent_core.Tool.t  (** What the turn places. *)
  ; already_used : Agent_core.Tool.t list
        (** The attached tools this conversation has run, placed with their
            schemas rather than behind the listing again.

            A load reaches the agent of the turn that made it and no further,
            so without this the model re-asks every turn: measured 2026-08-30,
            one Keeper asked for [github_issue_read] on five consecutive turns
            and for [github_get_label] 34 times in a day, and 39 of 84 turns
            that used the listing loaded a tool the turn then ended before
            using.

            Derived from history, the way the Claude API, Claude Code, and
            Hermes all carry a discovered tool forward: the conversation is
            the record, so a crash, a resume, or a failed turn needs no
            reconciliation.

            Read from the tools' own [ToolUse] blocks, not from what was asked
            for. Asking is not evidence of need, and carrying every request
            grows the surface back toward the full attached list -- measured
            an hour after that change shipped, one Keeper was at 111 tools of
            a possible 133 and still climbing. Use stops where the work stops.

            Empty until something runs, so a Keeper that never reaches its
            attached services pays nothing for this. The set is a fold over
            the conversation's own history, so it survives anything short of
            that history being dropped ([masc_keeper_clear], checkpoint
            purge). A restart is not one of those: it restores the same
            history from the checkpoint and rebuilds the same set.

            Cut back to [carry_window] on the calls that grow the carry -- a
            call to a tool the carry does not already hold. The tool array is
            the head of the provider's cache prefix (agent_core's Anthropic
            backend puts the [cache_control] breakpoint on the last tool), so
            a turn whose array differs from the turn before forfeits the
            cached read of the whole prefix, history included. A call to a
            name already carried leaves the array identical and is not cut on;
            a call to a name not carried grows the array and forfeits the
            prefix anyway, so the cut there costs no invalidation that was not
            already being paid. See [carry_window] for what that buys and what
            it gives up: the window is sampled at those calls, not enforced
            continuously, so between them a tool can age past it and stay
            placed.

            A tool the window drops returns to the listing on the same
            request, because the listing omits exactly the names placed with
            schemas. Nothing becomes unreachable; what changes is whether a
            tool's schema is charged before it is asked for. A call the model
            makes to a dropped name is refused by admission and costs a round
            trip -- see {!make} for what the model is told.

            The claim once made here that the 138 and 150-tool requests
            (masc#32939) are this set is withdrawn: those requests carry no
            listing at all -- they are official-client lanes, which pin their
            tool set at spawn and hold every tool as a schema. Measured
            2026-09-04 over 8,105 [kind:request] rows in
            [wire-capture/2026-09] with each request's tool array resolved
            through [tools_ref._blob.sha256]: requests with no
            [keeper_tool_search] in the array are 28.2% of all tool-schema
            bytes, and the (138, no-listing) and (150, no-listing) shapes
            account for 374 and 177 requests. Nothing here reaches them.

            The sizing figures below are inherited from the replay that chose
            the default and were produced against the earlier cut rule (cut at
            a name's first use in the conversation), not the rule above; they
            are the reason for the default rather than a measurement of what
            ships. Measured over 19,100 turns 2026-09-01..03: per-keeper median
            carried 32.1 KB falling to 17.4 KB at a window of 300, turns whose
            array differs rising from 1.0% to 3.3%, against 57,600 tokens of
            prefix at the measured median. The current rule cuts strictly more
            often than the rule those came from, so the carried figure is an
            upper bound and the differing-turns figure a lower one. Re-running
            the replay against this rule is not done. *)
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

val make : keeper_name:string -> surface -> placement option
(** The listing tool for one turn, or [None] when nothing is deferred.

    Every deferred tool is held here and callable; what changes is that the
    model is shown a name and a line rather than an argument schema until it
    asks.

    A tool whose schema is not placed is not in the running agent's callable
    set either, so a call the model makes to it by name is dropped by
    [Agent_core] admission before dispatch and the block does not enter the
    transcript. The model is told the name was not available on that request
    and is pointed at loading it through an offered listing; it is not told
    the name is unknown, because here it is not. Recovering costs one round
    trip. This is why the carry exists at all: a tool the conversation is
    still using should be placed rather than re-asked for.

    Raises [Invalid_argument] if the argument schema this builds is refused,
    which can only be a defect in the literal it is built from. *)
