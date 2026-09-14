(* RFC-0444 PR-2: the one projection of a [Goal_store.unavailable] value onto
   the wire. Every surface that answers with a store this build cannot read
   (MCP goal tools, task creation and assignment with goal_ids, the dashboard
   goal delete route, the proof confirmation route) calls this module; none
   renders the value itself, and none branches on the rendered line. *)

let error_code = Tool_args.Unavailable

let field_of_reason = function
  | Goal_store.Schema_rejected { field; _ } -> `String field
  | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Not_json _ -> `Null

let goal_count_of_mirror = function
  | Goal_store.Mirror_decodes { goal_count; _ } -> `Int goal_count
  | Goal_store.Mirror_absent | Goal_store.Mirror_unreadable _
  | Goal_store.Mirror_rejected _ -> `Null

let fields ({ file; reason; mirror; reset_step } : Goal_store.unavailable) =
  [ "reason", `String (Goal_store_unavailable.reason_name reason)
  ; "field", field_of_reason reason
  ; "file", `String file
  ; ( "mirror"
    , `Assoc
        [ "status", `String (Goal_store_unavailable.mirror_status_name mirror)
        ; "goal_count", goal_count_of_mirror mirror
        ] )
  ; "reset_step", `String (Goal_store_unavailable.reset_step_name reset_step)
  ]

let to_yojson (unavailable : Goal_store.unavailable) : Yojson.Safe.t =
  `Assoc
    ([ "ok", `Bool false
     ; "error_code", `String (Tool_args.error_code_to_string error_code)
     ]
     @ fields unavailable)

let tool_result ~tool_name ~start_time unavailable : Tool_result.result =
  let data = to_yojson unavailable in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Dependency_unavailable
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
