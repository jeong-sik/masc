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

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_field ?(default = "") key json =
  match assoc_field key json with
  | Some (`String value) -> value
  | _ -> default

let bool_field ?(default = false) key json =
  match assoc_field key json with
  | Some (`Bool value) -> value
  | _ -> default

let list_field_length key json =
  match assoc_field key json with
  | Some (`List values) -> List.length values
  | _ -> 0

let check_startup_state () =
  let startup = Server_startup_state.to_yojson () in
  let phase = string_field ~default:"unknown" "phase" startup in
  let state_ready = bool_field "state_ready" startup in
  let pending_lazy = list_field_length "pending_lazy_tasks" startup in
  let last_error = string_field "last_error" startup in
  let healthy = state_ready && not (String.equal phase "degraded") in
  let detail =
    if String.trim last_error = "" then
      Printf.sprintf "phase=%s ready=%b pending_lazy=%d"
        phase state_ready pending_lazy
    else
      Printf.sprintf "phase=%s ready=%b pending_lazy=%d error=%s"
        phase state_ready pending_lazy last_error
  in
  { name = "startup_state"; healthy; detail }

let check_subsystems () =
  let snapshot = Subsystem_health.to_yojson () in
  let total, dead =
    match snapshot with
    | `Assoc entries ->
      List.fold_left (fun (total, dead) (_name, json) ->
        let dead =
          match assoc_field "status" json with
          | Some (`String "dead") -> dead + 1
          | _ -> dead
        in
        (total + 1, dead)
      ) (0, 0) entries
    | _ -> (0, 0)
  in
  { name = "subsystem_health"
  ; healthy = total > 0 && dead = 0
  ; detail = Printf.sprintf "%d registered, %d dead" total dead
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

let check_metrics () =
  let all = Tool_metrics.all_stats () in
  let total_calls = List.fold_left (fun acc s -> acc + s.Tool_metrics.call_count) 0 all in
  { name = "tool_metrics"
  ; healthy = total_calls > 0
  ; detail = Printf.sprintf "%d tools, %d total calls" (List.length all) total_calls
  }

let all_checks () =
  [ check_startup_state ()
  ; check_subsystems ()
  ; check_hooks ()
  ; check_trace ()
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
