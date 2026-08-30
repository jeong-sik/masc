(** Tool_unified — Unified query interface across catalog, registry, and dispatch.

    Combines:
    - Tool_catalog: visibility, lifecycle, metadata
    - Tool_registry: call statistics (count, success, failure, duration)
    - Tool_dispatch: registration status
    - Tool_capability: read_only
*)

type tool_info = {
  name : string;
  visibility : Tool_catalog.visibility;
  lifecycle : Tool_catalog.lifecycle;
  is_registered : bool;
  is_read_only : bool;
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
    is_read_only = Tool_capability.has Tool_capability.Read_only name;
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
    ("call_stats", stats_json);
  ]

(** Summary report for dashboard. *)
let summary_report ?(runtime_metrics = fun () -> `Null) () : Yojson.Safe.t =
  let metrics = Tool_metrics.all_stats () in
  let total =
    List.fold_left
      (fun count (stats : Tool_metrics.tool_stats) -> count + stats.call_count)
      0
      metrics
  in
  let distinct = List.length metrics in
  let rec take count = function
    | [] -> []
    | _ when count <= 0 -> []
    | item :: rest -> item :: take (count - 1) rest
  in
  let top_20 = take 20 metrics in
  let all_names = Config.all_tool_names () in
  let allowed_names =
    List.filter (fun name -> Tool_catalog.is_visible name) all_names
  in
  let called_names =
    List.fold_left
      (fun names (stats : Tool_metrics.tool_stats) ->
         Set_util.StringSet.add stats.tool_name names)
      Set_util.StringSet.empty
      metrics
  in
  let never_called =
    List.filter
      (fun name -> not (Set_util.StringSet.mem name called_names))
      allowed_names
  in
  let total_count = List.length all_names in
  let visible_count = List.length allowed_names in
  let hidden_count = total_count - visible_count in
  let public_count =
    List.length Tool_catalog_surfaces.public_mcp_surface_tools
  in
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
    ( "top_20"
    , `List
        (List.map
           (fun (stats : Tool_metrics.tool_stats) ->
              `Assoc
                [ "name", `String stats.tool_name
                ; "call_count", `Int stats.call_count
                ; "p50_ms", `Float stats.p50_ms
                ; "p95_ms", `Float stats.p95_ms
                ; "p99_ms", `Float stats.p99_ms
                ; "mean_ms", `Float stats.mean_ms
                ; "success_count", `Int stats.success_count
                ; "failure_count", `Int stats.failure_count
                ])
           top_20) )
    ;
    ("never_called_count", `Int (List.length never_called));
    ("tool_distribution", tool_dist);
    ("registered_count", `Int (Tool_dispatch.registered_count ()));
    ("runtime_metrics", runtime_metrics ());
  ]
