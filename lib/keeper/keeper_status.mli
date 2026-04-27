(** Keeper_status — keeper list/trajectory/eval handlers and status dispatch.

    Single-keeper detail lives in [Keeper_status_detail]. This module
    is the dispatcher facade for the keeper status tools. *)

include module type of Keeper_status_bridge

type tool_result = Keeper_types.tool_result

(** Detail handler re-exported from [Keeper_status_detail]; returns
    a JSON-encoded keeper status snapshot for [args.name]. *)
val handle_keeper_status :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** List up to [args.limit] keepers (default 50) with optional
    [args.detailed] meta projection. *)
val handle_keeper_list :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Read recent trajectory entries (default 20) for the keeper named
    in [args.name], scoped to its current trace_id. *)
val handle_keeper_trajectory :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result

(** Run the keeper-eval projection (continuity/blocker summary) for
    [args.name]. *)
val handle_keeper_eval :
  _ Keeper_types.context -> Yojson.Safe.t -> tool_result
