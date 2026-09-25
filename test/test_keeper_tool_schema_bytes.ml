(** A ceiling on the complete model-visible tool schema inventory.

    [test_keeper_system_prompt_blocks] checks the assembled system prompt, which
    is the smaller half of the fixed per-turn cost. The tool array is the larger
    one and had no measurement at all: a tool added with a generous schema, or a
    description that grows a paragraph at a time, enlarges the available surface
    and nothing said so.

    This is a ratchet, not a golden. Shrinking passes and reports the slack, so
    a PR that trims a description is never asked to edit a number to stay green
    — a ratchet that fails on its own improvement takes main red for the
    duration. Growth past the ceiling fails and has to be argued for in
    the PR that causes it.

    [model_visible_schemas] projects the descriptors a Keeper can call, before
    deferred loading selects a particular turn's tools. Each carries the name,
    description, and input_schema serialized as compact JSON, so whitespace in
    the OCaml source does not move the number. This is a development measurement
    guard, not a runtime budget or a restriction on Keeper activity. *)

open Alcotest

(* Raise only with the PR that grows the surface, and say what it bought; the
   history of this number lives in git log, not here.

   123,650 is an estimate, not a reading. Main's test build was broken after
   #38976 (fixed by #39032), so this suite did not run on main while the
   surface grew past the previous ceiling. The first full run after the fix
   measured 123,620 on #39025, which trims 30 bytes from two descriptions, so
   main carries about 123,650. #39039's CI passed this suite at 123,650, which
   bounds the surface from above but prints no figure: the byte count is only
   reported when the ceiling is crossed. *)
let ceiling_bytes = 123_650

let schema_json (schema : Masc_domain.tool_schema) =
  `Assoc
    [ "name", `String schema.name
    ; "description", `String schema.description
    ; "input_schema", schema.input_schema
    ]
;;

let measured () =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas () in
  List.iter (fun (schema : Masc_domain.tool_schema) ->
    if List.mem schema.name
      ["keeper_workspace_memory_read"; "masc_lane_declaration_read"; "masc_lane_declaration_save"] then
      Printf.printf "model-visible schema %s: %d bytes\n%!" schema.name
        (String.length (Yojson.Safe.to_string (schema_json schema)))) schemas;
  let bytes =
    List.fold_left
      (fun acc schema -> acc + String.length (Yojson.Safe.to_string (schema_json schema)))
      0
      schemas
  in
  Printf.printf "model-visible schema inventory: %d bytes / %d tools; ceiling: %d bytes\n%!"
    bytes (List.length schemas) ceiling_bytes;
  (List.length schemas, bytes)
;;

(* Backward-compat golden: the tool surface a Keeper carries must not
   change without someone saying so, so a later refactor cannot quietly take
   a tool away. Pinned on 2026-08-23.

   The names, not a byte total. The invariant above is about which tools a
   Keeper can still call, and a byte count answers that only by accident. It
   was re-pinned four times in two days (#30679): #30539 added
   [keeper_code_query] and #30588 re-measured it, which is the surface really
   moving and what this golden is for; #30571 and #30658 only edited a
   description, and the surface they were asked to re-pin was the same one.

   All four landed red on main rather than on the PR that caused them. Someone
   editing config/tools/*.toml has no reason to run this file, and no type
   changes to make [dune build @check] say so -- the failure arrives after the
   merge, on everyone. Naming the tools cuts that to the two occasions where a
   Keeper's callable set actually changed, and those are worth stopping for.

   Sizing is not lost by the change: [ceiling_bytes] above bounds the same
   surface, and the slack check next to it fails when that ceiling drifts far
   enough to stop measuring. Those two are shaped as a ratchet on purpose --
   the doc at the top of this file argues that a golden which fails on its own
   improvement takes main red for the duration, which is exactly what this one
   did.

   A tool added or removed still fails here, and now says which one. *)
let all_surface_golden_names =
  [ "BrowserAct"
  ; "BrowserGoto"
  ; "BrowserInteract"
  ; "BrowserRead"
  ; "BrowserSession"
  ; "BrowserTabs"
  ; "Edit"
  ; "Execute"
  ; "Grep"
  ; "Read"
  ; "WebFetch"
  ; "WebSearch"
  ; "Write"
  (* Unread artifact handles need a model-callable vision reader. *)
  ; "keeper_analyze_image"
  ; "keeper_artifact_read"
  ; "keeper_artifact_transfer"
  ; "keeper_broadcast"
  ; "keeper_code_query"
  ; "keeper_context_status"
  ; "keeper_ide_annotate"
  ; "keeper_lane_status"
  ; "keeper_library_read"
  ; "keeper_library_search"
  ; "keeper_workspace_memory_read"
  ; "keeper_memory_search"
  ; "keeper_memory_retract"
  ; "keeper_memory_write"
  ; "keeper_constitution_write"
  ; "keeper_constitution_remove"
  ; "keeper_person_note_set"
  (* A Keeper can statically validate an artifact-backed Skill draft. *)
  ; "keeper_skill_validate"
  (* A Keeper can publish a new Skill package; operators delete afterwards. *)
  ; "keeper_skill_publish"
  ; "keeper_spawn"
  ; "keeper_spawn_read"
  ; "keeper_spawn_stop"
  ; "keeper_spawn_wait"
  ; "keeper_surface_post"
  ; "keeper_surface_read"
  ; "keeper_task_cancel"
  ; "keeper_task_claim"
  ; "keeper_task_create"
  ; "keeper_task_done"
  (* +1 for keeper_task_release: a Keeper could claim a task and never hand
     it back, so one that could not finish what it held was barred from all
     other work until it was shut down. *)
  ; "keeper_task_release"
  ; "keeper_tasks_audit"
  ; "keeper_tasks_list"
  ; "keeper_tools_list"
  ; "keeper_capability_search"
  ; "keeper_voice_agent"
  ; "keeper_voice_listen"
  ; "keeper_voice_session_end"
  ; "keeper_voice_session_start"
  ; "keeper_voice_sessions"
  ; "keeper_voice_speak"
    (* RFC-webmcp-keeper-consumption Lane B: WebMCP consumption rides the
       execute group, so the default surface carries both bridge tools. *)
  ; "keeper_webmcp_call"
  ; "keeper_webmcp_list"
  ; "masc_agent_fitness"
    (* +3 for the ask family: the answer→wake chain existed end to end, but
       without descriptors the agent-core lane never saw the tools, so no
       Keeper running in-process could ask the operator anything. *)
  ; "masc_ask"
  ; "masc_ask_status"
  ; "masc_ask_withdraw"
  ; "masc_board_cleanup"
  ; "masc_board_comment"
  ; "masc_board_comment_vote"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_delete"
  ; "masc_board_hearths"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_post_get"
  ; "masc_board_post_update"
  ; "masc_board_profile"
  ; "masc_board_reaction"
  ; "masc_board_search"
  ; "masc_board_stats"
  ; "masc_board_vote"
  ; "masc_config"
  ; "masc_dashboard"
  ; "masc_file_delete"
  ; "masc_file_list"
  ; "masc_file_upload"
  ; "masc_fusion"
  (* #34981: a Keeper's adopt/reject decision on a Fusion panel proposal
     lands in task history instead of only in the panel, so the next turn
     can read what was already decided. *)
  ; "masc_fusion_decision"
  ; "masc_fusion_status"
  ; "masc_gc"
  ; "masc_get_metrics"
  ; "masc_goal_list"
  ; "masc_goal_transition"
  ; "masc_goal_upsert"
  ; "masc_keeper_delegate"
  ; "masc_keeper_delegate_cancel"
  ; "masc_keeper_delegate_status"
  ; "masc_library_add"
  ; "masc_library_list"
  ; "masc_dos_click"
  ; "masc_dos_eject"
  ; "masc_dos_load"
  ; "masc_dos_pass"
  ; "masc_dos_peek"
  ; "masc_dos_press"
  ; "masc_dos_restore"
  ; "masc_dos_save"
  ; "masc_dos_screen"
  ; "masc_dos_step"
  ; "masc_dos_type"
  ; "masc_lane_attach"
  ; "masc_lane_declaration_read"
  ; "masc_lane_declaration_save"
  ; "masc_lane_act"
  ; "masc_lane_action_status"
  ; "masc_lane_detach"
  ; "masc_lane_evidence"
  ; "masc_lane_inspect"
  ; "masc_lane_observe"
  ; "masc_lane_slice"
  (* Subscription management and caller-bound output read/ack. *)
  ; "masc_lane_updates"
  ; "masc_msx_change_disk"
  ; "masc_msx_eject"
  ; "masc_msx_load"
  ; "masc_msx_peek"
  ; "masc_msx_press"
  ; "masc_msx_ram_diff"
  ; "masc_msx_restore"
  ; "masc_msx_save"
  ; "masc_msx_screen"
  ; "masc_msx_step"
  (* The existing settle action advances frames to a stable observation; record
     its deliberate model-visible addition without increasing the byte ceiling. *)
  ; "masc_msx_step_until_change"
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_run_get"
  ; "masc_run_init"
  ; "masc_run_list"
  ; "masc_run_plan"
  ; "masc_schedule_cancel"
  ; "masc_schedule_note_add"
  ; "masc_schedule_notes_list"
  ; "masc_schedule_create"
  ; "masc_schedule_get"
  ; "masc_schedule_list"
  ; "masc_schedule_update"
  ; "masc_task_history"
  ; "masc_task_set_goal"
  ]
;;

let test_all_surface_is_unchanged () =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas () in
  let names = List.sort String.compare (List.map (fun (s : Masc_domain.tool_schema) -> s.name) schemas) in
  let missing = List.filter (fun n -> not (List.mem n names)) all_surface_golden_names in
  let added = List.filter (fun n -> not (List.mem n all_surface_golden_names)) names in
  (match missing, added with
   | [], [] -> ()
   | _ ->
     failf
       "the default (All) tool surface changed.\n\
        gone: %s\n\
        new:  %s\n\
        A Keeper with no [keeper.tools] declaration gets this list. Update \
        all_surface_golden_names in this file with the PR that moves it and say \
        what the move bought."
       (if missing = [] then "(none)" else String.concat ", " missing)
       (if added = [] then "(none)" else String.concat ", " added));
  check int "All surface tool count unchanged"
    (List.length all_surface_golden_names)
    (List.length names)
;;


let test_tool_schema_bytes_stay_under_the_ceiling () =
  let count, bytes = measured () in
  check bool "the surface is non-empty" true (count > 0);
  if bytes > ceiling_bytes
  then
    failf
      "model-visible tool schemas grew to %d bytes across %d tools, over the %d ceiling \
       by %d.\n\
       This inventory includes deferred tools; this check is not a runtime budget. \
       This is what the CLI lane declares, not what a turn carries: masc cannot widen \
       an official-client tool set mid-turn (runtime_official_client_mcp.ml), so every \
       tool here is named at spawn -- but the client defers the schemas, and a turn \
       carries the names plus whatever the model reaches for (RFC-0451 SS8.6). An \
       agent_core-lane Keeper declares less: a deferrable tool leaves its request for \
       one listing. Trim the schema or \
       the description, or raise ceiling_bytes in this file with the PR that needs the \
       room and say what it bought. Choosing the set per Keeper before the turn starts \
       is the open question: RFC-0451."
      bytes
      count
      ceiling_bytes
      (bytes - ceiling_bytes)
;;

(* A ceiling nobody is near stops measuring anything. This fails when the slack
   grows past a third of the ceiling, which is the signal to lower it and bank
   the reduction: a baseline that has drifted far from what it measures is
   reporting on nothing. *)
let test_the_ceiling_still_tracks_the_surface () =
  let _, bytes = measured () in
  let slack = ceiling_bytes - bytes in
  if bytes <= ceiling_bytes && slack > ceiling_bytes / 3
  then
    failf
      "model-visible tool schemas are %d bytes against a %d ceiling — %d of slack. The \
       ceiling has stopped tracking the surface; lower it to bank the reduction."
      bytes
      ceiling_bytes
      slack
;;

let () =
  run
    "keeper_tool_schema_bytes"
    [ ( "per-turn tool surface"
      , [ test_case "stays under the ceiling" `Quick
            test_tool_schema_bytes_stay_under_the_ceiling
        ; test_case "the ceiling still tracks the surface" `Quick
            test_the_ceiling_still_tracks_the_surface
        ] )
    ; ( "surface golden"
      , [ test_case "the surface is unchanged (backward compat)" `Quick
            test_all_surface_is_unchanged
        ] )
    ]
;;
