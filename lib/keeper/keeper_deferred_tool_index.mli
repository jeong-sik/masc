(** Attached-service tools carried as an index instead of as schemas.

    Attaching a service loads every one of its tools into every provider
    request that Keeper makes, whether or not any of them is called. On
    2026-08-29 one Keeper carried 41 amplitude tools at 238,087 bytes — 58.7%
    of its request body — and called them zero times in seven days; the
    surface left 12KB for history and 412 turns died of context overflow.

    Here the same tools are carried as a name and a one-line summary, and the
    schema is handed over when the model asks for it by name. The measured
    encoding is 9.2% of the schemas it replaces.

    Only the Agent Core lane can use this. The official-client lanes pin their
    tool set at process spawn or thread start and make the surface part of a
    resumable session's identity, so a set widened mid-turn is a set they
    cannot accept — those lanes keep taking every tool. *)

type t

type surface =
  { always_loaded : Agent_core.Tool.t list
  ; deferred : (Agent_core.Types.tool_schema * Agent_core.Tool.t) list
  }
(** One turn's split. Carried as a pair so a lane cannot be handed the
    reduced tool list without the index that stands in for the rest: absent
    means no deferral and every tool is sent, which is what the
    official-client lanes and every non-Keeper caller get. *)

val search_tool_name : string
(** The one name a Keeper calls to turn an index row into a callable tool.
    Named here rather than at the use site because the approval policy has to
    recognise it without holding the index. *)

val create : (Agent_core.Types.tool_schema * Agent_core.Tool.t) list -> t
(** Index one turn's attached-service tools.

    The schema is the row's own; nothing is rewritten. The summary shown to
    the model is the first line of the tool's own description, truncated on a
    character boundary — a description is prose written by the service, and a
    byte-sliced one stops being UTF-8. *)

val is_empty : t -> bool

val count : t -> int

val index_text : t -> string
(** The index as the model reads it: one line per tool.

    This is carried in the search tool's own description rather than in a
    prompt block, so a lane that is not handed the search tool is not handed
    the index either. Nothing else has to know which lane it is on. *)

val select : t -> names:string list -> (Agent_core.Tool.t list, string) result
(** Resolve exact names. A name the index does not hold is an error naming it,
    not a nearest match: the catalog is closed and a Keeper that asked for the
    wrong name needs to read that, not to be handed a different tool. *)

val search_tool
  :  t
  -> extend:(Agent_core.Tool.t list -> (unit, string) result)
  -> Agent_core.Tool.t
(** The tool that hands over schemas. [extend] widens the running agent's
    callable set; the tools it returns answer from the next provider request
    of the same turn onward.

    [extend] returns a result because the agent it widens is published into a
    cell during turn setup, and a call that reaches this tool before the cell
    is filled has found a wiring defect. Reporting the schema anyway would
    hand the model a tool whose calls are then dropped before history with no
    error it can read.

    The result reports what it added. A model that reads the schema in the
    result and calls the tool in the same message would have that call dropped
    before history — the admission index is rebuilt per request, and this
    request's was built before [extend] ran. *)
