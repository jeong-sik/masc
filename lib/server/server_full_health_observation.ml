type snapshot = {
  workspace_epoch : Mcp_server.Workspace_scope_epoch.t option;
  scope_consistent : bool;
  fields : (string * Yojson.Safe.t) list;
  computed_at : float;
  duration_ms : int;
  failure : Proactive_refresh.failure option;
  stale_since_ts : float option;
  last_good_available : bool;
  section_timings : (string * int) list;
}

type t = {
  snapshot : snapshot option;
  consecutive_failures : int;
}

let empty = { snapshot = None; consecutive_failures = 0 }

let same_scope left right =
  match left, right with
  | Some left, Some right -> Mcp_server.Workspace_scope_epoch.equal left right
  | None, None -> true
  | (None | Some _), (None | Some _) -> false

let for_scope ~workspace_epoch state =
  match state.snapshot with
  | Some snapshot
    when not snapshot.scope_consistent
         || not (same_scope workspace_epoch snapshot.workspace_epoch) -> empty
  | None | Some _ -> state

let publish snapshot _state =
  { snapshot = Some snapshot; consecutive_failures = 0 }

let publish_dirty ~since snapshot state =
  let state = for_scope ~workspace_epoch:snapshot.workspace_epoch state in
  let stale_since =
    match state.snapshot with
    | Some { stale_since_ts = Some previous; _ } -> Float.min previous since
    | Some { stale_since_ts = None; _ } | None -> since
  in
  publish { snapshot with stale_since_ts = Some stale_since } state

let invalidate ~now state =
  let snapshot =
    Option.map
      (fun snapshot ->
        match snapshot.stale_since_ts with
        | Some _ -> snapshot
        | None -> { snapshot with stale_since_ts = Some now })
      state.snapshot
  in
  { state with snapshot }

let fail ~workspace_epoch ~now ~failure ~cold_fields ~critical_threshold state =
  let state = for_scope ~workspace_epoch state in
  let previous =
    match state.snapshot with
    | Some snapshot -> snapshot
    | None ->
        { workspace_epoch;
          scope_consistent = true;
          fields = cold_fields;
          computed_at = now;
          duration_ms = 0;
          failure = None;
          stale_since_ts = None;
          last_good_available = false;
          section_timings = []
        }
  in
  let stale_since_ts =
    match previous.stale_since_ts with
    | Some _ as since -> since
    | None -> Some now
  in
  let snapshot = { previous with failure = Some failure; stale_since_ts } in
  let consecutive_failures = state.consecutive_failures + 1 in
  { snapshot = Some snapshot; consecutive_failures },
  consecutive_failures = critical_threshold
