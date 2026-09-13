(** A ceiling on the complete model-visible tool schema inventory.

    [test_keeper_system_prompt_bytes] pins the assembled system prompt, which is
    the smaller half of the fixed per-turn cost. The tool array is the larger
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

   2026-08-30: 75,000. The surface measured 71,691 bytes across 83 tools that
   day and 71,812 across the same 83 on 2026-08-31, so 85,000 had stopped
   tracking it; the reduction is banked here.

   2026-09-02: Execute's schema went from a typed pipeline/then/redirect
   grammar -- 6,118 bytes of the 08-30 reading, used in 3 of 866 calls over
   two days -- to five parameters (argv, script, shell, cwd, timeout_sec)
   under a 694-byte description. The ceiling stays at 75,000; whether the
   slack that opens still sits inside a third of it is what
   [test_the_ceiling_still_tracks_the_surface] below answers.

   2026-09-06: 80,000. Structurally reduced model-visible tool schemas from
   86,749 bytes to 79,166 bytes across 90 tools (-7,583 bytes, -8.74%). Trimming
   disproportionate descriptions and redundant documentation in tool_execute,
   masc_ask, masc_ask_status, masc_ask_withdraw, keeper_code_query,
   keeper_webmcp_call, keeper_webmcp_list, keeper_spawn_wait, and
   keeper_spawn_read brings the surface comfortably below the 80,000 ceiling
   (#29595), leaving 834 bytes of deliberate headroom under the ratchet.

   2026-09-07: 85,000. Targeted CI run 34095215290 measured 84,699 bytes
   across 99 tools at c2b0243b84372bae88403e29cffde8f1209fa511. The restored
   keeper_analyze_image reader contributes 1,146 bytes, making stored images
   readable by text-only Keepers. The preceding surface was therefore
   83,553 bytes, already over the old ceiling; its Browser, file and Slack
   tools also had not been recorded in the name inventory below. This
   ceiling acknowledges that shipped surface and the reader, with 301 bytes
   of headroom over the measured result.

   2026-09-07: 88,000. masc_msx_load / eject / screen / press / step (RFC-0439
   §6.1) add 2,626 bytes: 87,626 across 104 tools. What it bought: a Keeper
   can play the workspace MSX machine through tools. All five declare
   defer_loading = true, so a Keeper that never names one carries none of
   them on the wire; this figure counts them because model_visible_schemas
   reads the descriptor and not the loading declaration. 374 bytes of
   headroom over the measured result.

   The figure is a reading, not a constant. What the ceiling holds is the
   slack, which [test_the_ceiling_still_tracks_the_surface] below bounds;
   the numbers here say where it came from. *)
(* Firefox controls: the production TOML loader measured BrowserAct at 1,628
   bytes, BrowserRead mode growth at 202, and BrowserGoto shrinkage at 18.
   Preserve the MSX tool surface ceiling's headroom: 88,000 + 1,628 + 202 - 18. *)
(* Contexts/dialogs/uploads add 862 measured schema bytes (BrowserRead +299,
   BrowserAct +563 including the Keeper file boundary), preserving the preceding ceiling headroom. *)
(* Downloads add 117 bytes measured with the production Tool_definition_toml
   renderer against contexts 21bfcdf89b: BrowserRead is 1493 -> 1610 bytes.
   No other schema changes in this unit; preserve the base surface headroom. *)
(* Main adds BrowserInteract: production TOML rendering is 1,394 bytes,
   or 1,388 with its public name, plus one list separator. BrowserGoto
   guidance grows by 33 bytes. Preserve the existing headroom after merge. *)
(* Explicit native client selection adds 1004 measured browser schema bytes. *)
(* Named MSX checkpoints add 884 schema bytes (literal TOML/golden JSON);
   preserve existing headroom. CI verifies the production renderer. *)
(* CI 34231934273 at 4f109263 measured 95,902 bytes across 108 tools,
   1,801 above the inherited ceiling after adding checkpoints. Account for
   that already-shipped surface explicitly, without adding headroom.
   Disk replacement adds 501 literal schema bytes; CI checks the renderer. *)
(* 2026-09-08: #34409 gave twelve deferred tools a first line that fits the
   line the model chooses them from. Before it, keeper_ide_annotate offered
   570 bytes into an 80-byte budget and masc_msx_load 553, so what the model
   saw of them was a sentence cut mid-word. Each gained a summary sentence
   and a blank line, and nothing was removed, so the surface grew.

   Argued here rather than in that PR because nothing said so at the time:
   this suite runs in the nightly lane and not on a pull request, so #34409
   merged green and the ceiling failed that night. Nightly 34258890189
   measured 97,067 bytes across 109 tools.

   The figure below is not that one. This pull request's own check measured
   97,663 across the same 109 tools -- the surface grew another 596 bytes in
   the merges between the nightly and it -- which is why the reading has to
   come from the run that is about to land rather than from last night.
   Set to keep the 501 bytes of headroom the line above accounts for.

   #34506 is the same shape and takes about 195 of that: five MSX tools
   whose first line was over the budget, the largest at 745 bytes. It fits
   under this figure, so the headroom it leaves is nearer 306. *)
(* 2026-09-10: the workspace memory reader adds 776 serialized bytes and one
   always-available tool. It lets Keepers discover and read attributed curator
   proposals, disagreements and source gaps without treating them as verified
   memory. Targeted CI 34401018154 at b33c497efb measured 98,808 bytes / 112
   tools after the Browser description reduction landed. The preceding
   surface is therefore 98,032 bytes / 111 tools. Add only the reader's 776
   bytes to the previous 98,164 ceiling, retaining exactly 132 bytes of slack.
   This is schema measurement, not a runtime token or behavior gate. *)
(* 2026-09-10: 100,456 across 113 tools, measured by targeted CI 34420702044
   at 8ccf4d6938. Four merges moved the surface past the line above and none
   of them argued it:

     #34981  masc_fusion_decision, the 113th tool (+1,124 bytes of TOML)
     #34983  masc_fusion carries the original Task and Goal text  (+623)
     #34963  masc_keeper_up reports the existing sandbox image     (+289)
     #34976  masc_goal_list admits the awaiting_confirmation phase  (+25)

   Those are raw TOML bytes and sum to 2,061; the renderer drops comments and
   formatting, so the serialized surface grew 1,648.

   Set to the measurement with no headroom. A ceiling that carries slack lets
   the next unargued growth land silently, which is how these four did.

   The lines above this one say the cause is that this suite runs nightly and
   not on a pull request. That was true when they were written and is not the
   cause here. #34506 mapped config/tools to this suite on 2026-09-09 00:04Z,
   and #34981 merged at 23:48Z the same day: its own check
   (run 34417530502) ran this suite and printed

     [FAIL] per-turn tool surface  0  stays under the ceiling.
     [FAIL] surface golden         0  the surface is unchanged

   and the step still reported success, because it carried
   continue-on-error until #35025 removed it on 2026-09-10 05:25Z. The guard
   ran, said so, and nothing was listening. From #35025 on, a pull request
   that grows the surface fails its own check. *)
(* 2026-09-11: 103,716 across 119 tools. PR adds 6 lane tools: masc_lane_attach,
   masc_lane_detach, masc_lane_evidence, masc_lane_inspect, masc_lane_observe,
   masc_lane_slice (+3,260 bytes). What it bought: Codex lane-addon runtime operations. *)
(* 2026-09-11: 105,415 across 121 tools (task-381). Adds masc_schedule_note_add and
   masc_schedule_notes_list (+1,931 rendered bytes). What it bought: durable schedule
   notes -- why a schedule exists, what changed across masc_schedule_update
   replacements, and what a Keeper needs when it wakes; append-only, keyed by the
   stable schedule_id, surviving terminal states. *)
(* 2026-09-11: 106,394 across 122 tools. PR adds keeper_artifact_transfer
   (+979 bytes). What it bought: a Keeper hands a generated binary to a peer
   through the workspace blob store, without either side touching the other's
   host paths. *)
(* 2026-09-12: 107,631 across 124 tools. PR adds keeper_constitution_write and
   keeper_constitution_remove (+1,237 bytes). What it bought: the keepers of a
   world write the norms they agreed on into the one place every keeper there
   reads, instead of an operator pasting them into a prompt override from the
   dashboard -- the only path that existed (RFC-0442). *)
(* Generic package action submission and receipt reading add two deferred
   tools. CI 34698460831 measured 109,254 bytes / 126 tools at ff6f80564b.
   Shortening the action summary by 18 ASCII bytes gives 109,236, with no
   added headroom. These tools connect optional package environments through
   one domain-independent path; package installation adds no per-domain tool.
   CI verifies the production renderer; this is not a Keeper behavior gate. *)
(* 2026-09-13: two Fusion description changes, measured apart and now carried
   together; no tool is added by either.

   masc_fusion_status +336 (109,572 across 126 tools, CI 34706931145 at
   596c9dc3): the description now says what a run_id read returns -- the
   original durable Board evidence, panel answers, judge advice, source context
   and evidence hash -- and that missing evidence is reported rather than read
   as an expired post. Without that, a Keeper attributes panel positions from
   metadata it did not check. The tool declares defer_loading = true, so these
   bytes reach the wire only on a turn that names it; this figure counts them
   because model_visible_schemas reads the descriptor, not the loading
   declaration.

   masc_fusion task_id +162 (109,398 across 126 tools, CI 34705880512 at
   09c8510e), from main: the parameter now says what happens when neither
   task_id nor goal_id is given -- the runtime picks the caller's active Task
   from authoritative ownership -- and that the captured contract and Goal
   criteria are separate from the caller's own summary. Without that a Keeper
   omits the argument expecting no Task, or restates the contract into the
   summary.

   Set to the measurements with no added headroom. *)
(* 2026-09-13: the DOS lane adds seven deferred tools -- masc_dos_load, _eject,
   _screen, _step, _press, _type, _peek. CI 34705960512 measured 114,705 bytes
   / 133 tools before trimming; the declarations then lost 883 rendered bytes
   of rationale that belongs in the code rather than in a string every turn
   carries, which is where this number comes from. What it bought: a second machine keepers drive the way they drive
   the MSX one (RFC-0439 §3.5) -- a real-mode DOS box that boots a program,
   takes keys, and says when it wants the next one, with every key in the
   ledger under the caller's name.

   Worth saying because the number keeps going one way: these two lanes now
   cost about 11.5 KB of every Keeper turn, and a Keeper that never plays a
   game still carries them. Tool sets scoped to the lanes a Keeper has
   attached would give it back; that is a change to how tools are attached,
   not to this file. RFC-0451 proposes it. *)

(* 2026-09-13: 114,500. The same PR, answering review: masc_dos_press and
   masc_dos_type now declare max_items = 64 and max_length = 256, and their
   results carry keys_pressed. Together that is 248 bytes, and 113,822 was
   set to the measured figure with no room, so the ceiling moves with it.
   What it bought: one call's work is bounded. The step budget is per key, so
   a thousand-character type call could run a billion instructions holding
   the machine's mutex; the caps and the ceiling inside Dos_lane.press_resolved
   bound it, and keys_pressed is how the caller learns the sequence stopped
   early. 430 bytes of headroom over the measured result. *)
(* 2026-09-13: native CI 34708251602 measured 110,899 bytes / 128 tools at
   bb9d1de3d1. The two declaration read/save tools add 1,663 rendered bytes
   to the previous 109,236-byte surface. They let Dashboard and Keeper edit
   the same installation TOML through one owner; adding a domain package
   needs no further tool. Set the ratchet to this measurement with no slack.
   This is the whole available catalog, including deferred tools, not a
   per-turn payload limit or Keeper activity budget. *)
(* Combining main's 114,500-byte baseline with the independently measured
   1,663-byte declaration editor addition preserves main's existing headroom.
   The combined production renderer is checked by the following native CI;
   this arithmetic is not a claim that the combined source has run yet. *)
(* Both deltas, on main's ceiling. They were measured independently and neither
   contains the other, so the sum is the combined surface rather than one
   change counted twice. main's existing headroom is preserved and the merge
   adds none; CI measures the result. *)
let ceiling_bytes = 116_163 + 162 + 336

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
  ; "masc_dos_eject"
  ; "masc_dos_load"
  ; "masc_dos_peek"
  ; "masc_dos_press"
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
       This is the CLI lane's bill: an official-client turn carries all of it, because \
       that transport answers requests and never originates, so no tool can be supplied \
       mid-turn (runtime_official_client_mcp.ml). An agent_core-lane Keeper carries \
       less -- a deferrable tool leaves its request for one listing. Trim the schema or \
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
