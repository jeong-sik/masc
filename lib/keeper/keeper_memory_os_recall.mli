(** Demand recall separates stored knowledge from per-turn context while
    injecting a frozen-per-memory-epoch Tier-1 ordinary memory digest compiled
    by {!Keeper_memory_digest}.

    Search-capable surfaces receive the cache-stable frozen-epoch ordinary
    memory digest (byte-identical across turns until the next Librarian commit
    or molt advances the revision — never ["bodies omitted"]), plus source-bound
    availability and lookup guidance. Authoritative demand recall retires the
    superseded current artifact pin, preserving dated history. *)

(** Render only the ordinary snapshot. Kept as the focused ordinary-store
    projection; production prompt assembly calls [render_if_enabled]. *)
val render_context
  :  keepers_dir:string
  -> keeper_id:string
  -> unit
  -> string

val enabled : unit -> bool

type rendered_recall =
  { text : string
  ; delivered_invalidations : Keeper_memory_source_current.invalidation list
    (** Exact source-bound invalidation records rendered into [text] on this
        turn. Empty when recall is disabled, the source store is absent or
        unavailable, or no invalidations were rendered. Callers retire these
        only after the turn and its receipt have committed via
        {!retire_after_turn_settlement}. *)
  }

type turn_settlement_status =
  | Turn_committed
  | Turn_not_committed

val render_demand_notice
  :  memory_select_route:Keeper_request_tool_access.route
  -> memory_search_available:bool
  -> config:Workspace.config
  -> keepers_dir:string
  -> keeper_id:string
  -> observed:(Keeper_recall_artifact.pin_observation, string) result
  -> rendered_recall

val render_if_enabled_with_delivered
  :  ?artifact_reader_available:bool
  -> ?memory_search_available:bool
  -> ?memory_select_route:Keeper_request_tool_access.route
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> rendered_recall option

val render_if_enabled
  :  ?artifact_reader_available:bool
  -> ?memory_search_available:bool
  -> ?memory_select_route:Keeper_request_tool_access.route
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option

(** Post-commit retirement gate preserving [failure_keeps_evidence]. Retires
    [delivered] invalidations via
    {!Keeper_memory_source_current.retire_delivered_invalidations} strictly when
    [settlement = Turn_committed]; leaves the store untouched and returns
    [Ok 0] on [Turn_not_committed]. Non-cancellation filesystem/lock exceptions
    are caught and returned as [Error] so post-commit retirement cannot abort
    an already-committed turn; [Eio.Cancel.Cancelled] propagates unchanged. *)
val retire_after_turn_settlement
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> settlement:turn_settlement_status
  -> delivered:Keeper_memory_source_current.invalidation list
  -> unit
  -> (int, string) result

(** Returns a block for every state, including disabled or unavailable recall.
    The option-shaped interface is shared with the prompt assembly. *)
