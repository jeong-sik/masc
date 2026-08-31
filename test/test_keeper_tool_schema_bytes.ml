(** A ceiling on the tool schemas every Keeper turn carries.

    [test_keeper_system_prompt_bytes] pins the assembled system prompt, which is
    the smaller half of the fixed per-turn cost. The tool array is the larger
    one and had no measurement at all: a tool added with a generous schema, or a
    description that grows a paragraph at a time, costs every turn of every
    Keeper and nothing said so.

    This is a ratchet, not a golden. Shrinking passes and reports the slack, so
    a PR that trims a description is never asked to edit a number to stay green
    — a ratchet that fails on its own improvement takes main red for the
    duration. Growth past the ceiling fails and has to be argued for in
    the PR that causes it.

    What is measured is what the model receives: [model_visible_schemas]
    projects the descriptors a Keeper can call, and each carries the name,
    description, and input_schema that go on the wire. Serialized as compact
    JSON, so whitespace in the OCaml source does not move the number. *)

open Alcotest

(* Raise only with the PR that grows the surface, and say what it bought.
   2026-08-07: 72,485 bytes across 98 model-visible tools — 7.9x the assembled
   system prompt (9,167 bytes, pinned next door). The headroom is deliberate
   slack for one ordinary tool, not room to grow into.

   2026-08-23: 85,000. What it bought is nothing, and that is the finding. The
   surface reached 88,138 bytes across 95 tools — three fewer tools carrying
   15,653 more bytes — with no PR to attribute it to: 45 commits touched
   lib/tool_surface and the descriptor over those two weeks and the growth is
   spread across them. The same PR that moves this number takes 4,288 bytes
   back out of [Execute], whose redirect objects spelled "exactly one of these
   keys" as a oneOf branch per pair of property names.

   What is left to take is measured and not taken here. The Execute schema
   ships the same prose several times over — the argv paragraph four times, the
   fd sentence eight — because the exec-stage shape repeats at the top level,
   inside pipeline, inside then, and inside then's pipeline. That is 4,158
   bytes of duplicated description, and JSON Schema names the fix ($defs and
   $ref). Sending one meant knowing every provider resolves it, which was not
   a thing to guess at on the surface every turn carries. Both halves are done
   now -- the probes below, then the collapse the paragraph after them
   records.

   Every lane was probed with the same two-variant experiment: one logical
   tool offered flat and with $defs/$ref, one prompt naming the same nested
   values, compare the arguments the model produced. Each ran through its own
   transport, so what was measured is the lane and not just the model behind
   it -- codex over [app-server --stdio] dynamicTools, antigravity over the
   stdio MCP config agy reads.

     ollama-cloud minimax-m3   resolves, exact args   (2026-08-29)
     zai glm-4.6               resolves, exact args   (2026-08-29)
     codex app-server          resolves, exact args   (2026-08-30)
     antigravity agy 1.1.22    resolves, exact args   (2026-08-30)

   One caveat found on the way, for a lane that does not exist yet: Gemini's
   legacy [parameters] field rejects $defs and $ref by name at payload
   parsing, before auth ("Unknown name \"$defs\" ... Cannot find field"). agy
   does not use that field, which is why its lane passes. A future
   direct-Gemini lane must send [parametersJsonSchema]. *)
(* Lowered from 85,000 on 2026-08-30, banking what naming Execute's repeated
   exec-stage shapes gave back: the surface measured 71,691 bytes across 83
   tools that day, down 2,925 from 74,616, and Execute itself went 9,049 ->
   6,118. That is the whole of the repeat: no other tool ships a shape twice,
   so this is not a lever to pull again and the next reduction comes from
   somewhere else.

   The figure is a reading, not a constant -- 71,812 across the same 83 tools
   on 2026-08-31, the surface having grown 121 bytes since. What the ceiling
   holds is the slack, which [test_the_ceiling_still_tracks_the_surface]
   below bounds; the numbers here say where it came from. *)
let ceiling_bytes = 75_000

let schema_json (schema : Masc_domain.tool_schema) =
  `Assoc
    [ "name", `String schema.name
    ; "description", `String schema.description
    ; "input_schema", schema.input_schema
    ]
;;

(* Measured after [Json_schema_shared_defs.collapse], because that is what
   [Tool_bridge] hands the provider and so what the model is charged for. The
   descriptor's own schema stays expanded for argument validation; counting it
   here would report a surface nothing sends. *)
let measured () =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas () in
  let bytes =
    List.fold_left
      (fun acc (schema : Masc_domain.tool_schema) ->
         acc
         + String.length
             (Yojson.Safe.to_string
                (schema_json
                   { schema with
                     input_schema =
                       Json_schema_shared_defs.collapse schema.input_schema
                   })))
      0
      schemas
  in
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
  [ "Edit"
  ; "Execute"
  ; "Grep"
  ; "Read"
  ; "WebFetch"
  ; "WebSearch"
  ; "Write"
  ; "keeper_artifact_read"
  ; "keeper_broadcast"
  ; "keeper_code_query"
  ; "keeper_context_status"
  ; "keeper_ide_annotate"
  ; "keeper_library_read"
  ; "keeper_library_search"
  ; "keeper_memory_search"
  ; "keeper_memory_write"
  ; "keeper_person_note_set"
  ; "keeper_spawn"
  ; "keeper_spawn_read"
  ; "keeper_spawn_stop"
  ; "keeper_spawn_wait"
  ; "keeper_surface_post"
  ; "keeper_surface_read"
  ; "keeper_task_claim"
  ; "keeper_task_create"
  ; "keeper_task_done"
  (* +1 for keeper_task_release: a Keeper could claim a task and never hand
     it back, so one that could not finish what it held was barred from all
     other work until it was shut down. *)
  ; "keeper_task_release"
  ; "keeper_tasks_audit"
  ; "keeper_tasks_list"
  ; "keeper_time_now"
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
  ; "masc_fusion"
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
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_run_get"
  ; "masc_run_init"
  ; "masc_run_list"
  ; "masc_run_plan"
  ; "masc_schedule_cancel"
  ; "masc_schedule_create"
  ; "masc_schedule_get"
  ; "masc_schedule_list"
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
       Every Keeper turn carries this. Trim the schema or the description, or raise \
       ceiling_bytes in this file with the PR that needs the room and say what it bought."
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
