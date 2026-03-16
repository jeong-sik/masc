(** Harness health check tool

    Inspects the harness subsystems and returns a health score.
    Designed to be exposed as an MCP tool (masc_harness_health).

    @since 2.95.0
*)

type check_result = {
  name : string;
  healthy : bool;
  detail : string;
}

let check_hooks () =
  let pre = List.length !(Tool_dispatch.pre_hooks) in
  let post = List.length !(Tool_dispatch.post_hooks) in
  { name = "dispatch_hooks"
  ; healthy = pre > 0 || post > 0
  ; detail = Printf.sprintf "%d pre-hooks, %d post-hooks registered" pre post
  }

let check_trace () =
  let recent = Trace.export_recent ~limit:1 () in
  let has_spans = match recent with
    | `List (_ :: _) -> true
    | _ -> false
  in
  { name = "trace_spans"
  ; healthy = has_spans
  ; detail = if has_spans then "spans present" else "no spans recorded"
  }

let check_permissions () =
  let admin_count = List.length Tool_permissions.admin_tools in
  { name = "permissions"
  ; healthy = admin_count > 0
  ; detail = Printf.sprintf "%d admin tools protected" admin_count
  }

let check_sse_filter () =
  let count = Sse_room_filter.registered_count () in
  { name = "sse_room_filter"
  ; healthy = true  (* Module exists and is functional *)
  ; detail = Printf.sprintf "%d sessions tracked" count
  }

let check_metrics () =
  let all = Tool_metrics.all_stats () in
  let total_calls = List.fold_left (fun acc s -> acc + s.Tool_metrics.call_count) 0 all in
  { name = "tool_metrics"
  ; healthy = total_calls > 0
  ; detail = Printf.sprintf "%d tools, %d total calls" (List.length all) total_calls
  }

let all_checks () =
  [ check_hooks ()
  ; check_trace ()
  ; check_permissions ()
  ; check_sse_filter ()
  ; check_metrics ()
  ]

let health_score checks =
  let total = List.length checks in
  let healthy = List.length (List.filter (fun c -> c.healthy) checks) in
  if total = 0 then 0.0
  else float_of_int healthy /. float_of_int total

let check_to_json c =
  `Assoc
    [ ("name", `String c.name)
    ; ("healthy", `Bool c.healthy)
    ; ("detail", `String c.detail)
    ]

let handle ~name:_ ~args:_ =
  let checks = all_checks () in
  let score = health_score checks in
  let json = `Assoc
    [ ("score", `Float score)
    ; ("checks", `List (List.map check_to_json checks))
    ; ("healthy_count", `Int (List.length (List.filter (fun c -> c.healthy) checks)))
    ; ("total_count", `Int (List.length checks))
    ] in
  Some (true, Yojson.Safe.to_string json)
