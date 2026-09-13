(* RFC-0444 §2.1: the value a goal store this build cannot read produces.

   It lives in masc_types, below both masc_workspace and masc_goal, because
   the task-creation contract in masc_workspace carries it
   ([Workspace_task_create.Goal_source_unavailable]) while the store that
   builds it, masc_goal, depends on masc_workspace. [Goal_store] re-exports
   every constructor so store callers keep writing [Goal_store.Schema_rejected]. *)

type t =
  { file : string
  ; reason : reason
  ; mirror : mirror_status
  ; reset_step : reset_step
  }

and reason =
  | Missing_after_init
  | Unreadable of Unix.error
  | Not_json of string
  | Schema_rejected of { field : string; detail : string }

and mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_decodes of { goal_count : int; updated_at : string }
  | Mirror_rejected of reason

and reset_step =
  | Repair_field of string
  | Reset_goal_store
  | Restore_permission

(* {1 Wire names}

   The constructor name in lowercase snake case. These are the tokens the
   RFC-0444 envelope carries in [reason], [mirror.status] and [reset_step];
   the TS union (PR-3) and [Tui_decode] variant (PR-4) parse them exactly. *)

let reason_name = function
  | Missing_after_init -> "missing_after_init"
  | Unreadable _ -> "unreadable"
  | Not_json _ -> "not_json"
  | Schema_rejected _ -> "schema_rejected"

let mirror_status_name = function
  | Mirror_absent -> "mirror_absent"
  | Mirror_unreadable _ -> "mirror_unreadable"
  | Mirror_decodes _ -> "mirror_decodes"
  | Mirror_rejected _ -> "mirror_rejected"

let reset_step_name = function
  | Repair_field _ -> "repair_field"
  | Reset_goal_store -> "reset_goal_store"
  | Restore_permission -> "restore_permission"

(* {1 Rendering}

   One line for surfaces whose terminus is a string (prompt fragments, WARN
   lines). Render at the very end; never branch on the output. *)

let reason_to_string = function
  | Missing_after_init ->
      "missing_after_init (goals.json is absent while its .last-good mirror exists)"
  | Unreadable error -> "unreadable (" ^ Unix.error_message error ^ ")"
  | Not_json detail -> "not_json (" ^ detail ^ ")"
  | Schema_rejected { field; detail } ->
      Printf.sprintf "schema_rejected field=%s (%s)" field detail

let mirror_status_to_string = function
  | Mirror_absent -> "absent"
  | Mirror_unreadable error -> "unreadable (" ^ Unix.error_message error ^ ")"
  | Mirror_decodes { goal_count; updated_at } ->
      Printf.sprintf "decodes goal_count=%d updated_at=%s" goal_count updated_at
  | Mirror_rejected reason -> "rejected " ^ reason_to_string reason

let reset_step_to_string = function
  | Repair_field field -> "repair field " ^ field
  | Reset_goal_store -> "reset the goal store"
  | Restore_permission -> "restore read permission on the file"

let to_string { file; reason; mirror; reset_step } =
  Printf.sprintf "goal_store: unavailable reason=%s file=%s mirror=%s reset=%s"
    (reason_to_string reason)
    file
    (mirror_status_to_string mirror)
    (reset_step_to_string reset_step)
