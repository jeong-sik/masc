(** Tool_unified — Unified query interface across catalog, registry, and dispatch.

    Combines:
    - Tool_catalog: visibility, lifecycle, metadata
    - Tool_registry: call statistics (count, success, failure, duration)
    - Tool_dispatch: registration status, read_only, join_required
*)

type tool_info = {
  name : string;
  visibility : Tool_catalog.visibility;
  lifecycle : Tool_catalog.lifecycle;
  is_registered : bool;
  is_read_only : bool;
  is_join_required : bool;
  call_stats : Tool_registry.call_stats option;
}

let tool_info name : tool_info =
  let meta = Tool_catalog.metadata name in
  let stats =
    let all = Tool_registry.get_stats () in
    List.assoc_opt name all
  in
  {
    name;
    visibility = meta.visibility;
    lifecycle = meta.lifecycle;
    is_registered = Tool_dispatch.is_registered name;
    is_read_only = Tool_dispatch.is_read_only name;
    is_join_required = Tool_dispatch.is_join_required name;
    call_stats = stats;
  }

let tool_info_to_json (info : tool_info) : Yojson.Safe.t =
  let stats_json = match info.call_stats with
    | None -> `Null
    | Some s ->
      (* #10730 changed [Tool_registry.call_stats] fields from plain
         scalars to [Atomic.t] cells but missed two consumer sites
         here.  Read each cell once at JSON build time so the report
         sees a consistent snapshot. *)
      `Assoc [
        ("call_count", `Int (Atomic.get s.call_count));
        ("success_count", `Int (Atomic.get s.success_count));
        ("failure_count", `Int (Atomic.get s.failure_count));
        ("last_called_at", `Float (Atomic.get s.last_called_at));
        ("total_duration_ms", `Int (Atomic.get s.total_duration_ms));
      ]
  in
  `Assoc [
    ("name", `String info.name);
    ("visibility", `String (Tool_catalog.visibility_to_string info.visibility));
    ("lifecycle", `String (Tool_catalog.lifecycle_to_string info.lifecycle));
    ("is_registered", `Bool info.is_registered);
    ("is_read_only", `Bool info.is_read_only);
    ("is_join_required", `Bool info.is_join_required);
    ("call_stats", stats_json);
  ]

(** Summary report for dashboard. *)
let summary_report () : Yojson.Safe.t =
  let total = Tool_registry.total_calls () in
  let distinct = Tool_registry.distinct_tools_called () in
  let top_20 = Tool_registry.get_top_n 20 in
  let all_names = Config.all_tool_names () in
  let visible_names =
    List.filter (fun name -> Tool_catalog.is_visible name) all_names
  in
  let never_called = Tool_registry.get_never_called visible_names in
  let total_count = List.length all_names in
  let visible_count = List.length visible_names in
  let hidden_count = total_count - visible_count in
  let public_count = List.length Tool_catalog.public_mcp_tools in
  let tool_dist =
    `Assoc [
      ("total", `Int total_count);
      ("public", `Int public_count);
      ("visible", `Int visible_count);
      ("hidden", `Int hidden_count);
    ]
  in
  `Assoc [
    ("total_calls", `Int total);
    ("distinct_tools_called", `Int distinct);
    ("top_20",
     `List (List.map (fun (name, stats) ->
       let latency = match Tool_metrics.stats_for name with
         | Some s ->
           [ ("p50_ms", `Float s.p50_ms); ("p95_ms", `Float s.p95_ms)
           ; ("p99_ms", `Float s.p99_ms); ("mean_ms", `Float s.mean_ms)
           ; ("success_count", `Int s.success_count)
           ; ("failure_count", `Int s.failure_count) ]
         | None -> []
       in
       `Assoc ([
         ("name", `String name);
         ("call_count", `Int (Atomic.get stats.Tool_registry.call_count));
       ] @ latency)
     ) top_20));
    ("never_called_count", `Int (List.length never_called));
    ("tool_distribution", tool_dist);
    ("dispatch_v2_enabled", `Bool Tool_dispatch.v2_enabled);
    ("registered_count", `Int (Tool_dispatch.registered_count ()));
    ("cascade_metrics", Oas_worker.cascade_metrics_json ());
  ]
