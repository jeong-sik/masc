(** Wake-turn task, trigger, and goal context contracts. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt
module Turn = Masc.Keeper_turn
module Inputs = Masc.Keeper_world_observation_inputs

let skill_reference name revision =
  let source_id =
    match Skill_source_config.source_id_of_string "project-masc" with
    | Ok source_id -> source_id
    | Error detail -> fail detail
  in
  let package_id =
    match Skill_reference.package_id_of_directory name with
    | Ok package_id -> package_id
    | Error _ -> failf "invalid Skill package fixture %S" name
  in
  let content_revision =
    match Skill_reference.content_revision_of_string (String.make 64 revision) with
    | Ok content_revision -> content_revision
    | Error _ -> fail "invalid Skill revision fixture"
  in
  Skill_reference.make
    ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name)
    ~content_revision
;;

(* The prompts these tests render ship inside the binary and reach a config
   directory through [Managed_asset_sync], which is the step the server takes
   at boot. Unpacking them once is the whole of this suite's prompt setup.

   What this replaced was two answers to one question: a per-test wrapper that
   pinned the repository's own [config/prompts] and cleared the registry when
   it left, and a suite-wide init that pinned a directory without reading it.
   The wrapper found the repository by climbing up to eight directories from
   the cwd, which a Dune sandbox does not contain, and its clear was global —
   it reached every later test that did not wrap itself, which then read the
   emptied registry as a missing prompt. One source, read once, has neither
   problem. *)
let unpacked_prompt_config =
  lazy
    (let config_dir = Filename.temp_dir "wake_turn_context_config_" "" in
     let prompts_dir = Filename.concat config_dir "prompts" in
     Unix.mkdir prompts_dir 0o700;
     (* [Config_dir_resolver] reports on both children; make the second one so
        a resolution warning does not ride along with every run. *)
     Unix.mkdir (Filename.concat config_dir "keepers") 0o700;
     let sync =
       Masc.Managed_asset_sync.sync
         ~domain:Masc.Managed_asset_sync.Prompts
         ~edit_layer:Masc.Managed_asset_sync.No_edit_layer
         ~read:Embedded_config.read
         ~files:Embedded_config.file_list
         ~dest_dir:prompts_dir
         ()
     in
     (match sync.Masc.Managed_asset_sync.failed with
      | [] -> ()
      | failures ->
          Alcotest.failf "the binary's prompt assets did not unpack: %s"
            (String.concat "; "
               (List.map (fun (rel, msg) -> rel ^ ": " ^ msg) failures)));
     (config_dir, prompts_dir))

(* Pinning the directory is only half of it. [keeper.workspace] is a slot
   inside [keeper.md] since the fragment files were folded into their group
   files, and slot keys exist only once the directory has been read — pinning
   alone leaves the registry looking for a [keeper.workspace.md] that no
   longer exists, which is what "Prompt 'keeper.workspace' is missing" was.
   [set_markdown_dir] then [Prompt_defaults.init] is the pair
   [Prompt_defaults.bootstrap_runtime] performs at boot. *)
let init_prompt_config_for_tests () =
  let config_dir, prompts_dir = Lazy.force unpacked_prompt_config in
  Unix.putenv "MASC_CONFIG_DIR" config_dir;
  Config_dir_resolver.reset ();
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc.Prompt_defaults.init ()

let base_observation : WO.world_observation =
  {
    pending_messages = [];
    pending_board_events = [];
    idle_seconds = 0;
    active_goals = Ok [];
    unclaimed_task_count = 0;
    claimable_tasks = [];
    held_task_skills = [];
    failed_task_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    approval_authority =
      { revision = 1; state = WO.Approval_authority_complete; pending = [] };
    backlog_revision = Some 1;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
    connected_surface_failures = [];
    own_recent_board_posts = [];
    fleet_messages = [];
    own_recent_actions = Ok [];
  }

let meta_of_json json =
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let meta : Masc.Keeper_meta_contract.keeper_meta =
  meta_of_json
    (`Assoc
      [
        ("name", `String "wake-context-keeper");
        ("trace_id", `String "test-trace-wake-context");
      ])

let prompt_config = lazy (Masc.Workspace.default_config "/tmp/unused")

(* The autonomous trigger section requires a configured default runtime. *)
let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "wake_turn_context_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

(* Normalize wrapping so assertions match prompt sentences rather than lines. *)
let count_occurrences ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop offset count =
    if needle_length = 0 || offset + needle_length > haystack_length then count
    else if String.sub haystack offset needle_length = needle
    then loop (offset + needle_length) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

let make_task ?(handoff_context = None) ~task_status () : Masc_domain.task =
  {
    id = "task-42";
    title = "Wire the wake-turn context";
    description = "test task";
    task_status;
    priority = 3;
    files = [];
    created_at = "2026-07-07T00:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context;
    cycle_count = 0;
    reclaim_policy = None;
    execution_links = Masc_domain.no_execution_links;
    do_not_reclaim_reason = None;
    skills = [];
  }

let user_message ?turn_decision ?current_task ?active_goal_summaries
    ?previous_turn_stop observation =
  let turn_decision =
    Option.value
      turn_decision
      ~default:(WO.keeper_cycle_decision ~meta observation)
  in
  let current_task =
    match current_task with
    | Some task -> Inputs.Current_task task
    | None -> Inputs.No_current_task
  in
  let { Prompt.world_state = user; _ } =
    Prompt.build_prompt ~turn_decision
      ?previous_turn_stop ~current_task ?active_goal_summaries ~observation ()
  in
  user

(* --- Previous turn stop: the loop guard's reason reaches the next turn --- *)

(* The live shape from 2026-09-01: one live keeper ended 259 of 361
   turns on the same repeated Jira query and repeated it next turn. The line
   has to name the tool and the count, because that is what the model can
   match against its own history. *)
let test_repeated_tool_call_stop_is_named_in_the_next_prompt () =
  let body =
    user_message
      ~previous_turn_stop:
        (Masc.Keeper_turn_checkpoint_reason.Repeated_tool_call
           { tool_name = "atlassian_searchJiraIssuesUsingJql"; repeated_count = 3 })
      base_observation
  in
  check bool "the section that carries wake reasons carries the stop" true
    (contains ~needle:"### Autonomous Trigger" body);
  check bool "the tool is named" true
    (contains ~needle:"`atlassian_searchJiraIssuesUsingJql` was called 3 times" body);
  check bool "the model is told the result did not change" true
    (contains ~needle:"returned the same result" body)
;;

let test_repeated_text_stop_is_named_in_the_next_prompt () =
  let body =
    user_message
      ~previous_turn_stop:
        (Masc.Keeper_turn_checkpoint_reason.Repeated_assistant_text
           { repeated_count = 3 })
      base_observation
  in
  check bool "the repeated-message count is named" true
    (contains ~needle:"wrote the same message 3 times" body)
;;

let test_no_previous_stop_renders_no_line () =
  let body = user_message base_observation in
  check bool "a completed or first turn says nothing about a previous stop" false
    (contains ~needle:"- Previous turn:" body)
;;

(* --- Own Recent Actions: arguments ride on refusals --- *)

let action_turn turn_id calls : Masc.Keeper_own_recent_actions.turn =
  { turn_id; calls }
;;

let call ~tool ~input ~outcome : Masc.Keeper_own_recent_actions.call =
  { Masc.Keeper_own_recent_actions.tool; input; outcome }
;;

let own_recent_actions_section body =
  let marker = "### Your Recent Actions" in
  match Astring.String.find_sub ~sub:marker body with
  | None -> ""
  | Some start ->
    let rest = String.sub body start (String.length body - start) in
    (match Astring.String.find_sub ~sub:"\n###" rest with
     | None -> rest
     | Some stop -> String.sub rest 0 stop)
;;

(* The live shape that starved keeper [analyst] on 2026-08-23: turns whose
   successful calls carry large argument objects. 1,312 successes carried
   538,743 bytes against 20 refusals carrying 6,417. *)
let test_successful_call_arguments_are_not_replayed () =
  let big = String.make 4000 'x' in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        Ok [ action_turn
            360
            (List.init 20 (fun i ->
               call
                 ~tool:"keeper_tool_execute"
                 ~input:(Printf.sprintf "{\"i\":%d,\"payload\":\"%s\"}" i big)
                 ~outcome:Masc.Keeper_own_recent_actions.Ok_call))
        ]
    }
  in
  let body = user_message observation in
  let section = own_recent_actions_section body in
  check bool "the calls are still listed" true
    (Option.is_some
       (Astring.String.find_sub ~sub:"[turn 360] keeper_tool_execute -> ok" section));
  check bool
    (Printf.sprintf "no argument body is replayed (section is %d bytes)"
       (String.length section))
    true
    (Option.is_none (Astring.String.find_sub ~sub:big section))
;;

let test_refused_call_keeps_its_arguments () =
  let payload = "{\"task_id\":\"task-471\",\"note\":\"needs-approval\"}" in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        Ok [ action_turn
            361
            [ call
                ~tool:"keeper_task_done"
                ~input:payload
                ~outcome:(Masc.Keeper_own_recent_actions.Failed_call (Some "not verified"))
            ]
        ]
    }
  in
  let body = user_message observation in
  let section = own_recent_actions_section body in
  check bool "the refused call keeps what was sent" true
    (Option.is_some (Astring.String.find_sub ~sub:payload section));
  check bool "and says why it was refused" true
    (Option.is_some (Astring.String.find_sub ~sub:"REJECTED: not verified" section))
;;

(* The digest is the salience fix: a keeper re-read the same nonexistent paths
   every autonomous turn on 2026-08-28 while the refusals were already inside
   this window, buried in the row matrix. Five turns of the same rejected
   read must surface as one counted row, ahead of the rows. *)
let test_failure_digest_dedupes_and_counts () =
  let path = "{\"path\":\"/repos/masc/lib/keeper/keeper_sandbox_control.ml\"}" in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        Ok (List.init 5 (fun i ->
            action_turn
              (370 + i)
              [
                call
                  ~tool:"tool_read_file"
                  ~input:path
                  ~outcome:
                    (Masc.Keeper_own_recent_actions.Failed_call
                       (Some "docker_cat_failed: No such file or directory"));
              ]))
    }
  in
  let body = user_message observation in
  let section = own_recent_actions_section body in
  check bool "digest heading present" true
    (Option.is_some (Astring.String.find_sub ~sub:"Rejected already" section));
  check bool "the same rejected read is counted once" true
    (Option.is_some (Astring.String.find_sub ~sub:" ×5 " section));
  check bool "and keeps its newest refusal reason" true
    (Option.is_some
       (Astring.String.find_sub
          ~sub:"docker_cat_failed: No such file or directory" section))
;;

let test_no_digest_without_failures () =
  let observation =
    { base_observation with
      WO.own_recent_actions =
        Ok [ action_turn
            380
            [ call
                ~tool:"masc_board_list"
                ~input:"{}"
                ~outcome:Masc.Keeper_own_recent_actions.Ok_call ]
        ]
    }
  in
  let body = user_message observation in
  let section = own_recent_actions_section body in
  check bool "no digest heading without refusals" true
    (Option.is_none (Astring.String.find_sub ~sub:"Rejected already" section))
;;

(* --- 1. Current Task layer --- *)

let test_small_failed_payloads_remain_retrievable () =
  let open Masc in
  let module Actions = Masc.Keeper_own_recent_actions in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "small-action-payloads-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let schema = Masc.Keeper_runtime_schemas_toml.artifact_read in
  let reader = Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ args ->
      let execution = Masc.Keeper_artifact_read.handle ~base_path ~args in
      match execution.disposition with
      | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:schema.name
          ~start_time:0. ?data:execution.data ()
      | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:schema.name
          ~class_ ~start_time:0. execution.raw_output
      | Tool_result.Deferred () -> fail "artifact read unexpectedly deferred") in
  let payload = "{\"patch\":\"" ^ String.make 32000 'x' ^ "\"}" in
  let detail = "Patch rejected: " ^ String.make 16000 'd' in
  let failed = call ~tool:"Edit" ~input:payload ~outcome:(Actions.Failed_call (Some detail)) in
  let success = call ~tool:"Read" ~input:"unchanged-success" ~outcome:Actions.Ok_call in
  let source = [action_turn 42 [failed; success]; action_turn 43 [failed]] in
  let render turns = user_message {base_observation with WO.own_recent_actions=Ok turns} in
  let original = render source in
  let project ~base_path ~policy ~tools =
    Actions.externalize_failures ~base_path ~keeper_name:"fixture" ~policy ~tools source in
  check string "Wide keeps the complete briefing" original
    (render (project ~base_path ~policy:Masc.Keeper_input_policy.Wide ~tools:[reader]));
  check string "missing reader keeps the complete briefing" original
    (render (project ~base_path ~policy:Masc.Keeper_input_policy.Small ~tools:[]));
  let projected = project ~base_path ~policy:Masc.Keeper_input_policy.Small ~tools:[reader] in
  let projected_call = match projected with
    | [{Actions.turn_id=42;calls=[call; untouched]}; {turn_id=43;calls=[repeated]}] ->
      check bool "successful call is untouched" true (untouched = success);
      check bool "identical failures retain identical references" true (call = repeated);
      call
    | _ -> fail "projection changed turn coordinates or call ordering" in
  let reference text = match Tool_output.decode_from_agent_core text with
    | Tool_output.Decoded reference -> reference
    | _ -> fail "failed payload was not externalized" in
  let argument_ref = reference projected_call.input in
  let detail_ref = match projected_call.outcome with
    | Actions.Failed_call (Some detail) -> reference detail
    | _ -> fail "projection changed the failed outcome" in
  let read_exact (reference : Tool_output.artifact_ref) =
    let rec loop offset parts =
      let execution = Masc.Keeper_artifact_read.handle ~base_path
        ~args:(`Assoc ["sha256", `String reference.sha256; "offset", `Int offset;
          "max_bytes", `Int Masc.Keeper_artifact_read.maximum_max_bytes]) in
      match execution.disposition, execution.data with
      | Tool_result.Completed (), Some json ->
        let open Yojson.Safe.Util in
        let content = json |> member "content" |> to_string in
        let next = json |> member "next_offset" |> to_int in
        let parts = content :: parts in
        if json |> member "eof" |> to_bool then String.concat "" (List.rev parts)
        else if next > offset then loop next parts else fail "artifact read made no progress"
      | _ -> fail "real artifact reader failed" in
    loop 0 [] in
  check string "arguments are retrievable byte for byte" payload (read_exact argument_ref);
  check string "failure detail is retrievable byte for byte" detail (read_exact detail_ref);
  let body = render projected in
  check bool "briefing shrinks without cutting source" true (String.length body < String.length original);
  check bool "call identity and rejected outcome remain visible" true
    (contains ~needle:"[turn 42] Edit" body && contains ~needle:"REJECTED" body);
  check bool "digest and ordinary row both retain the complete argument reference" true
    (count_occurrences ~needle:projected_call.input body >= 3);
  check string "original source remains unchanged" original (render source);
  let blocked = Filename.concat base_path "blocked-store" in
  Out_channel.with_open_bin blocked (fun channel -> output_string channel "not a directory");
  check string "storage failure keeps the complete briefing" original
    (render (project ~base_path:blocked ~policy:Masc.Keeper_input_policy.Small ~tools:[reader]))
;;

let test_current_task_section_renders () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ~handoff_context:
        (Some
           {
             summary = "lexer done, parser half-wired";
             reason = None;
             next_step = Some "wire parser to store";
             failure_mode = None;
             reclaim_policy = None;
             evidence_refs = [];
             updated_at = None;
             updated_by = None;
           })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "section header" true
    (contains ~needle:"### Current Task (held by you)" user);
  check bool "task id and title" true
    (contains ~needle:"- task-42 — Wire the wake-turn context" user);
  check bool "status line" true
    (contains ~needle:"in progress (wake-context-keeper) since 2026-07-07T01:00:00Z" user);
  (* An unattributed handoff stays explicit when author metadata is absent. *)
  check bool "handoff summary with attribution" true
    (contains
       ~needle:"- Prior handoff (unattributed): lexer done, parser half-wired"
       user);
  check bool "handoff next step" true
    (contains ~needle:"- Suggested next step: wire parser to store" user);
  check bool "no evidence line when the note records no refs" false
    (contains ~needle:"- Handoff evidence:" user)

(* task-364: the other held tasks' skills get their own lines. *)
let test_held_task_skills_section_renders () =
  let user =
    user_message
      { base_observation with
        held_task_skills =
          [ { Inputs.held_task_id = "task-364"
            ; held_skills =
                [ skill_reference "prior-art" 'a'
                ; skill_reference "work-intake" 'b'
                ]
            }
          ]
      }
  in
  check bool "heading" true (contains ~needle:"### Skills Named by Tasks You Hold" user);
  check bool "line names the task and exact skills" true
    (contains ~needle:"task-364 (held by you) names exact Skill catalog rows: [{" user
     && contains ~needle:"\"name\":\"prior-art\"" user
     && contains ~needle:"\"name\":\"work-intake\"" user);
  check bool "unprojected refs are explicitly unavailable" true
    (contains ~needle:"\"kind\":\"unavailable\"" user);
  check bool "unprojected refs do not invent keeper_skill" false
    (contains ~needle:"`keeper_skill`" user)

let test_held_task_skills_section_absent_without_held_tasks () =
  let user = user_message base_observation in
  check bool "no heading without held skills" false
    (contains ~needle:"Skills Named by Tasks You Hold" user)

(* The projection reads ownership off the tasks: held by this keeper, naming
   a skill, and not the current task. *)
let test_held_task_skills_projection () =
  let config = Lazy.force prompt_config in
  let assignee = meta.name in
  let held id ~by ~skills ~status =
    let task_status =
      match status with
      | `Claimed -> Masc_domain.Claimed { assignee = by; claimed_at = "2026-08-26T00:00:00Z" }
      | `In_progress -> Masc_domain.InProgress { assignee = by; started_at = "2026-08-26T00:00:00Z" }
    in
    { (make_task ~task_status ()) with id; skills }
  in
  let tasks =
    [ held "task-42" ~by:assignee ~skills:[ skill_reference "a" 'a' ] ~status:`In_progress
    ; held "task-43" ~by:assignee
        ~skills:[ skill_reference "b" 'b'; skill_reference "c" 'c' ] ~status:`Claimed
    ; held "task-44" ~by:"someone-else" ~skills:[ skill_reference "d" 'd' ] ~status:`Claimed
    ; held "task-45" ~by:assignee ~skills:[] ~status:`In_progress
    ; { (make_task ~task_status:Masc_domain.Todo ()) with
        id = "task-46"
      ; skills = [ skill_reference "e" 'e' ]
      }
    ]
  in
  let meta =
    { meta with
      current_task_id = Some (Keeper_id.Task_id.of_string "task-42" |> Result.get_ok) }
  in
  let projected = Inputs.held_task_skills_of_tasks ~config ~meta tasks in
  check (list string) "only the other held task that names skills"
    [ "task-43" ]
    (List.map (fun (h : Inputs.held_task_skills) -> h.held_task_id) projected);
  check (list string) "its skills in declaration order"
    [ "b"; "c" ]
    (List.concat_map
       (fun (h : Inputs.held_task_skills) ->
         List.map
           (fun (reference : Skill_reference.t) -> reference.identity.name)
           h.held_skills)
       projected);
  let meta = { meta with current_task_id = None } in
  check (list string) "without a current task both held tasks project"
    [ "task-42"; "task-43" ]
    (List.map (fun (h : Inputs.held_task_skills) -> h.held_task_id)
       (Inputs.held_task_skills_of_tasks ~config ~meta tasks))

let test_current_task_section_absent_without_task () =
  let user = user_message base_observation in
  check bool "no section without current task" false
    (contains ~needle:"### Current Task" user)

let task_id_exn value =
  match Keeper_id.Task_id.of_string value with
  | Ok task_id -> task_id
  | Error message -> fail message

let test_current_task_unavailable_is_explicit () =
  (* The needles assert the configured prose — the
     [observation.current_task_unobservable] slot of [keeper.md] — so the
     suite's prompts have to be loaded; without them the renderer falls back
     to different built-in wording. *)
  let task_id = task_id_exn "task-42" in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt
      ~turn_decision:decision
      ~current_task:
        (Inputs.Current_task_unavailable
           { task_id; error = "primary and recovery backlog decode failed" })
      ~observation:base_observation ()
  in
  check bool "task id remains visible" true
    (contains ~needle:"Task task-42 could not be observed" world_state);
  check bool "unavailable is not rendered as absent" true
    (contains ~needle:"does not mean the task is absent" world_state);
  check bool "storage error is not prompt content" false
    (contains ~needle:"primary and recovery backlog decode failed" world_state)

let test_current_task_missing_is_explicit () =
  let task_id = task_id_exn "task-42" in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt
      ~turn_decision:decision
      ~current_task:(Inputs.Current_task_missing { task_id; recovery = None })
      ~observation:base_observation ()
  in
  check bool "dangling id remains visible" true
    (contains ~needle:"references task-42" world_state);
  check bool "missing record forbids invented details" true
    (contains ~needle:"Do not infer or invent task details" world_state)

let test_recovered_current_task_is_non_authoritative () =
  let recovered_task : Masc_domain.task =
    make_task ~task_status:(Masc_domain.Todo : Masc_domain.task_status) ()
  in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let recovery : Masc.Workspace.backlog_recovery =
    { recovery_path = "/tmp/backlog.last-good"; primary_error = "decode failed" }
  in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt
      ~turn_decision:decision
      ~current_task:
        (Inputs.Recovered_current_task { task = recovered_task; recovery })
      ~observation:base_observation ()
  in
  check bool "recovery is not asserted as held authority" false
    (contains ~needle:"Current Task (held by you)" world_state);
  check bool "recovery authority is explicit" true
    (contains
       ~needle:"Current Task (recovery observation; non-authoritative)"
       world_state);
  check bool "mutation authority is forbidden" true
    (contains ~needle:"Do not use this recovery observation as mutation authority" world_state);
  check bool "primary parser error is not prompt content" false
    (contains ~needle:"decode failed" world_state)

let test_direct_turn_reuses_current_task_context () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ~handoff_context:
        (Some
           {
             summary = "parser is ready for a direct reply";
             reason = None;
             next_step = Some "answer with the current parser status";
             failure_mode = None;
             reclaim_policy = None;
             evidence_refs = [];
             updated_at = None;
             updated_by = None;
           })
      ()
  in
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~lane_updates:(Ok (`List []))
      ~workspace_memory:Masc.Workspace_memory_publication.Missing
      ~current_task:(Inputs.Current_task task)
      ~held_task_skills:[]
      ~task_skill_surfaces:[]
      ~approval_authority_text:"approval authority"
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:"worktree state"
      ~telemetry_feedback_text:"telemetry state"
      ~turn_instructions_text:"turn instructions"
  in
  check int "current task is injected exactly once" 1
    (count_occurrences
       ~needle:"### Current Task (held by you)"
       context);
  check bool "held task id and title" true
    (contains ~needle:"task-42 — Wire the wake-turn context" context);
  check bool "handoff is available to direct reply" true
    (contains ~needle:"parser is ready for a direct reply" context);
  check bool "other fresh direct context is preserved" true
    (contains ~needle:"recent owner message" context);
  check bool "direct reply carries current approval authority" true
    (contains ~needle:"approval authority" context)

(* task-364: the direct-message lane carries the held tasks' skills even when
   no task is current, so an owner asking the keeper about the work it just
   claimed gets the same skill lines the scheduled lane renders. *)
let test_direct_turn_carries_held_task_skills () =
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~lane_updates:(Ok (`List []))
      ~workspace_memory:Masc.Workspace_memory_publication.Missing
      ~current_task:Inputs.No_current_task
      ~held_task_skills:
        [ { Inputs.held_task_id = "task-364"
          ; held_skills = [ skill_reference "prior-art" 'a' ]
          }
        ]
      ~task_skill_surfaces:[]
      ~approval_authority_text:"approval authority"
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:""
      ~telemetry_feedback_text:""
      ~turn_instructions_text:""
  in
  check bool "held skills heading" true
    (contains ~needle:"### Skills Named by Tasks You Hold" context);
  check bool "held exact skills line" true
    (contains ~needle:"task-364 (held by you) names exact Skill catalog rows: [{" context
     && contains ~needle:"\"name\":\"prior-art\"" context);
  check bool "catalog row is conditional on this attempt's schema" true
    (contains ~needle:"only when that tool is present in the current attempt's tool schema" context
     && contains ~needle:"a runtime may suppress all tools" context);
  check bool "no synthetic current task" false (contains ~needle:"### Current Task" context)

let test_direct_turn_has_no_synthetic_task_context () =
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~lane_updates:(Ok (`List []))
      ~workspace_memory:Masc.Workspace_memory_publication.Missing
      ~current_task:Inputs.No_current_task
      ~held_task_skills:[]
      ~task_skill_surfaces:[]
      ~approval_authority_text:""
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:""
      ~telemetry_feedback_text:""
      ~turn_instructions_text:""
  in
  check bool "no held task means no synthetic task context" false
    (contains ~needle:"### Current Task" context);
  check string "non-task context remains" "recent owner message" context

let test_direct_turn_discovers_published_workspace_memory () =
  let module Publication = Masc.Workspace_memory_publication in
  let module Store = Masc.Workspace_memory_proposal in
  let module Inventory = Masc.Workspace_memory_context in
  let base_path = Filename.temp_dir "direct-workspace-memory" "" in
  let require = function Ok value -> value | Error detail -> fail detail in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let inventory = Inventory.collect ~base_path |> require in
    let envelope = Inventory.proposal_json inventory
      (`Assoc ["shared_claims", `List []; "conflicts", `List []; "excluded", `List []]) in
    let proposal_id = match Store.submit ~base_path envelope with
      | Ok (id, _) -> id
      | Error (Invalid detail | Unavailable detail) -> fail detail in
    Publication.publish ~base_path ~proposal_id |> require;
    let render () = Turn.For_testing.direct_turn_dynamic_context
      ~lane_updates:(Ok (`List []))
      ~workspace_memory:(Publication.observe ~base_path)
      ~current_task:Inputs.No_current_task ~held_task_skills:[] ~task_skill_surfaces:[]
      ~approval_authority_text:"" ~recent_direct_conversation_text:"owner conversation"
      ~worktree_text:"" ~telemetry_feedback_text:"" ~turn_instructions_text:"" in
    let direct = render () in
    List.iter (fun needle -> check bool "direct reply can inspect attributed shared proposal" true
      (contains ~needle direct))
      [proposal_id; "keeper_workspace_memory_read"; "model_proposed"; "not_performed";
       "not_checked_against_current_memory"; "owner conversation"];
    let shared = Prompt.format_workspace_memory_observation (Publication.observe ~base_path)
      |> Option.get in
    check bool "direct reply uses the same shared publication renderer" true
      (contains ~needle:shared direct);
    check string "unchanged observation does not accumulate briefing text" direct (render ());
    let target = Filename.concat base_path
      (Common.masc_dirname ^ "/workspace-memory/proposals/" ^ proposal_id ^ ".json") in
    Sys.remove target;
    let unavailable = render () in
    check bool "missing referenced proposal is explicitly unavailable" true
      (contains ~needle:"Discovery is unavailable" unavailable);
    check bool "unavailable direct reply does not reuse a stale read target" false
      (contains ~needle:proposal_id unavailable))

let test_open_goal_store_keeps_one_stable_safety_contract () =
  let meta_with_goal =
    meta_of_json
      (`Assoc
        [
          ("name", `String "wake-context-keeper");
          ("trace_id", `String "test-trace-wake-context");
        ])
  in
  let config = Masc.Workspace.default_config "/tmp/unused" in
  let base_system_prompt =
    match
      Masc.Keeper_run_context.build_base_system_prompt
        ~config
        ~profile_defaults:
          Masc.Keeper_types_profile_defaults.empty_keeper_profile_defaults
        ~meta:meta_with_goal
    with
    | Ok prompt -> prompt
    | Error error -> fail (Masc.World_constitution_store.read_error_to_string error)
  in
  check bool "removed per-Keeper goal id is absent" false
    (contains ~needle:"- missing-goal\n" base_system_prompt);
  check bool "identity block is preserved" true
    (contains ~needle:"<identity>" base_system_prompt);
  (* Direct and autonomous turns both send this one prompt. *)
  check bool "shared system block is preserved" true
    (contains ~needle:"<system>" base_system_prompt)

(* --- 2. Threaded turn decision --- *)

let test_threaded_stimulus_decision_renders_wake_reason () =
  (* A bootstrap event-queue stimulus on an otherwise empty world: the real
     scheduler decision knows the trigger; a local recompute cannot. *)
  let decision =
    WO.keeper_cycle_decision
      ~event_queue_triggers:[ WO.Bootstrap_stimulus ]
      ~meta base_observation
  in
  check bool "fixture: stimulus decision runs" true decision.WO.should_run;
  let threaded = user_message ~turn_decision:decision base_observation in
  check bool "wake-reason section present" true
    (contains ~needle:"### Autonomous Trigger" threaded);
  check bool "reactive scheduler line" true
    (contains ~needle:"- Scheduler: reactive turn (external stimulus)." threaded);
  check bool "bootstrap reason listed" true
    (contains ~needle:"bootstrap" threaded)

let test_bootstrap_stimulus_keeps_reactive_post_action () =
  let decision =
    WO.keeper_cycle_decision
      ~event_queue_triggers:[ WO.Bootstrap_stimulus ]
      ~meta
      base_observation
  in
  match
    Masc.Keeper_unified_turn_success.For_testing.post_action_of_channel
      decision.WO.channel
  with
  | Masc.Keeper_unified_turn_success.For_testing.Assign_task -> ()
  | Masc.Keeper_unified_turn_success.For_testing.Empty_queue_sleep ->
    Alcotest.fail
      "bootstrap stimulus must not be reclassified from reactive to scheduled"

let test_preview_does_not_invent_wake_reason () =
  let preview_meta =
    { meta with
      Masc.Keeper_meta_contract.name = "preview-must-not-emit-turn-metrics"
    }
  in
  let segment_metric = Keeper_metrics.(to_string PromptSegmentBytes) in
  let segment_labels =
    [ "keeper", preview_meta.name; "segment", "system_prompt" ]
  in
  let instruction_hash_metric =
    Keeper_metrics.(to_string KeeperTurnInstructionHash)
  in
  check bool "fixture has no preview segment metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          segment_metric
          ~labels:segment_labels
          ()));
  check bool "fixture has no preview hash metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          instruction_hash_metric
          ~labels:[ "keeper", preview_meta.name ]
          ()));
  let { Prompt.world_state; _ } =
    Prompt.build_prompt_preview
      ~current_task:Inputs.No_current_task
      ~observation:base_observation
      ()
  in
  check bool "preview has no scheduler trigger" false
    (contains ~needle:"### Autonomous Trigger" world_state);
  check bool "preview does not emit segment metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          segment_metric
          ~labels:segment_labels
          ()));
  check bool "preview does not emit instruction hash" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          instruction_hash_metric
          ~labels:[ "keeper", preview_meta.name ]
          ()))

(* A Keeper subscribed to a Lane output learns about an unread retained
   observation from the turn prompt itself, on both the direct and the
   autonomous path. Every earlier case here passed [Ok (`List [])], so the
   layer's rendering of an actual notice was never pinned: it names the
   subscription, the reading position and the tool that reads it, and carries
   no source rows. An unreadable configuration is reported, not silenced. *)
let lane_notice =
  `Assoc
    [ ( "subscription",
        `Assoc
          [ "keeper_name", `String "imp";
            "run_id", `String "dos-demo";
            "installation_id", `String "dos-demo";
            "output_id", `String "guest" ] );
      "instance_id", `String "01a09f1b-1e11-7000-9e2e-3bf8e3ec79f0";
      "after_sequence", `Int 1;
      "latest_sequence", `Int 3;
      "new_observations", `Bool true;
      "replaced", `Bool false ]

let direct_context ~lane_updates =
  Turn.For_testing.direct_turn_dynamic_context
    ~lane_updates
    ~workspace_memory:Masc.Workspace_memory_publication.Missing
    ~current_task:Inputs.No_current_task
    ~held_task_skills:[]
    ~task_skill_surfaces:[]
    ~approval_authority_text:"approval authority"
    ~recent_direct_conversation_text:"recent owner message"
    ~worktree_text:"worktree state"
    ~telemetry_feedback_text:"telemetry state"
    ~turn_instructions_text:"turn instructions"

let check_lane_notice_rendered ~lane context =
  check int (lane ^ ": the subscription notice is rendered once") 1
    (count_occurrences ~needle:"Subscribed Lane observation references" context);
  check bool (lane ^ ": the notice names the installation and output") true
    (contains ~needle:"\"installation_id\":\"dos-demo\"" context
     && contains ~needle:"\"output_id\":\"guest\"" context);
  check bool (lane ^ ": the notice carries the reading position") true
    (contains ~needle:"\"after_sequence\":1" context
     && contains ~needle:"\"latest_sequence\":3" context);
  check bool (lane ^ ": the notice points at the reading tool") true
    (contains ~needle:"masc_lane_updates" context
     && contains ~needle:"operation=read" context);
  check bool (lane ^ ": no source body travels with the reference") true
    (contains ~needle:"No source bodies are included" context)

let test_direct_turn_renders_an_unread_lane_notice () =
  check_lane_notice_rendered ~lane:"direct"
    (direct_context ~lane_updates:(Ok (`List [ lane_notice ])));
  check bool "direct: an empty notice list adds no lane section" false
    (contains ~needle:"Subscribed Lane observation references"
       (direct_context ~lane_updates:(Ok (`List []))));
  check bool "direct: an unreadable configuration is reported" true
    (contains ~needle:"Lane subscriptions unavailable"
       (direct_context ~lane_updates:(Error "lane-subscriptions.toml: parse error")))

let test_autonomous_turn_renders_an_unread_lane_notice () =
  let preview ~lane_updates =
    let { Prompt.world_state; _ } =
      Prompt.build_prompt_preview
        ~current_task:Inputs.No_current_task
        ~observation:base_observation
        ~lane_updates
        ()
    in
    world_state
  in
  check_lane_notice_rendered ~lane:"autonomous"
    (preview ~lane_updates:(Ok (`List [ lane_notice ])));
  check bool "autonomous: an empty notice list adds no lane section" false
    (contains ~needle:"Subscribed Lane observation references"
       (preview ~lane_updates:(Ok (`List []))))

(* AwaitingVerification does not hold a claim, so its heading must not imply
   active ownership. *)
let test_submitted_task_heading_does_not_claim_a_hold () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.AwaitingVerification
           { assignee = "wake-context-keeper"
           ; started_at = "2026-07-07T01:00:00Z"
           ; submitted_at = "2026-07-07T02:00:00Z"
           ; intent = Complete_task
           ; verification_id = "vrf-task-42"
           })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "not called held" false
    (contains ~needle:"Current Task (held by you)" user);
  check bool "the heading states what it is instead" true
    (contains
       ~needle:"### Current Task (submitted for verification; it does not hold your claim)"
       user);
  check bool "the row still carries the task" true
    (contains ~needle:"- task-42 — Wire the wake-turn context" user);
  check bool "and its status" true
    (contains ~needle:"awaiting verification (submitted 2026-07-07T02:00:00Z)" user)

let test_in_progress_task_heading_still_says_held () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "a task actually held is still called held" true
    (contains ~needle:"### Current Task (held by you)" user)

(* --- 3. Goal titles --- *)

let test_goal_summaries_render_titles () =
  let observation = { base_observation with active_goals = Ok [ "goal-x" ] } in
  let with_titles =
    user_message
      ~active_goal_summaries:(Ok
        [ { Prompt.summary_goal_id = "goal-x"
          ; summary_title = "Improve wake context"
          ; summary_criterion = None
          ; summary_review_note = None
          ; summary_phase = None
          }
        ])
      observation
  in
  check bool "id and title" true
    (contains ~needle:"- goal-x — Improve wake context" with_titles)

(* The caller resolves the goals linked to this turn's task. Omitting them
   used to mean the workspace's whole open-goal list, read off
   [observation.active_goals] -- the same list #32665 took out of the system
   prompt, arriving in the turn context instead. The observation below still
   carries an open goal, and the layer still has to be absent. *)
let test_no_summaries_renders_no_goal_layer () =
  let observation = { base_observation with active_goals = Ok [ "goal-x" ] } in
  let bare = user_message observation in
  check bool "no Active Goals heading" false
    (contains ~needle:"### Active Goals" bare);
  check bool "no goal id from the observation" false
    (contains ~needle:"goal-x" bare)

(* The heading and the list are read off one list, so the keeper is never told
   it holds goals the block does not name. *)
let test_goal_heading_counts_what_the_block_lists () =
  let observation =
    { base_observation with active_goals = Ok [ "goal-a"; "goal-b" ] }
  in
  let user =
    user_message
      ~active_goal_summaries:(Ok
        [ { Prompt.summary_goal_id = "goal-a"
          ; summary_title = "Improve wake context"
          ; summary_criterion = None
          ; summary_review_note = None
          ; summary_phase = None
          }
        ])
      observation
  in
  check bool "heading counts the rendered goals" true
    (contains ~needle:"### Active Goals (1)" user);
  check bool "the rendered goal carries its title" true
    (contains ~needle:"- goal-a — Improve wake context" user);
  check bool "no goal is counted without being named" false
    (contains ~needle:"goal-b" user)

let test_task_identities_are_parsed_once_per_backlog_list () =
  let todo = (Masc_domain.Todo : Masc_domain.task_status) in
  let tasks =
    [ make_task ~task_status:todo ()
    ; { (make_task ~task_status:todo ()) with id = "task-43" }
    ]
  in
  let first = Inputs.tasks_with_identities_memoized tasks in
  let second = Inputs.tasks_with_identities_memoized tasks in
  check bool "the same list is answered from the memo" true (first == second);
  (match first with
   | Ok identities -> check int "every task keeps its identity" 2 (List.length identities)
   | Error reason -> fail reason);
  let changed = List.tl tasks in
  let third = Inputs.tasks_with_identities_memoized changed in
  check bool "a different list is parsed afresh" false (third == first);
  match third with
  | Ok identities -> check int "and answers for that list" 1 (List.length identities)
  | Error reason -> fail reason

let () =
  init_prompt_config_for_tests ();
  init_runtime_default_for_tests ();
  run "keeper_wake_turn_context"
    [
      ( "current task layer",
        [
          test_case "renders id, status, and handoff" `Quick
            test_current_task_section_renders;
          test_case "absent without a held task" `Quick
            test_current_task_section_absent_without_task;
          test_case "held task skills section renders" `Quick
            test_held_task_skills_section_renders;
          test_case "held task skills section absent without held tasks" `Quick
            test_held_task_skills_section_absent_without_held_tasks;
          test_case "held task skills projection" `Quick
            test_held_task_skills_projection;
          test_case "unavailable backlog remains explicit" `Quick
            test_current_task_unavailable_is_explicit;
          test_case "dangling task id remains explicit" `Quick
            test_current_task_missing_is_explicit;
          test_case "recovery task is explicitly non-authoritative" `Quick
            test_recovered_current_task_is_non_authoritative;
          test_case "direct reply receives the held task and handoff" `Quick
            test_direct_turn_reuses_current_task_context;
          test_case "direct reply invents no task when none is held" `Quick
            test_direct_turn_has_no_synthetic_task_context;
          test_case "direct turn carries held task skills" `Quick
            test_direct_turn_carries_held_task_skills;
          test_case "direct reply discovers shared proposal with source uncertainty" `Quick
            test_direct_turn_discovers_published_workspace_memory;
          test_case "unresolved goal keeps one stable safety contract" `Quick
            test_open_goal_store_keeps_one_stable_safety_contract;
        ] );
      ( "threaded turn decision",
        [
          test_case "stimulus decision renders wake reason" `Quick
            test_threaded_stimulus_decision_renders_wake_reason;
          test_case "bootstrap keeps reactive post-action" `Quick
            test_bootstrap_stimulus_keeps_reactive_post_action;
          test_case "preview invents no wake reason" `Quick
            test_preview_does_not_invent_wake_reason;
        ] );
      ( "subscribed lane observations reach the turn prompt",
        [
          test_case "the direct turn renders an unread notice" `Quick
            test_direct_turn_renders_an_unread_lane_notice;
          test_case "the autonomous turn renders an unread notice" `Quick
            test_autonomous_turn_renders_an_unread_lane_notice;
        ] );
      ( "current task heading states the status",
        [
          test_case "a submitted task is not called held" `Quick
            test_submitted_task_heading_does_not_claim_a_hold;
          test_case "an in-progress task is still called held" `Quick
            test_in_progress_task_heading_still_says_held;
        ] );
      ( "own recent actions carry arguments on refusals",
        [
          test_case "a successful call replays no argument body" `Quick
            test_successful_call_arguments_are_not_replayed;
          test_case "a refused call keeps what was sent" `Quick
            test_refused_call_keeps_its_arguments;
          test_case "Small failed payloads remain retrievable through the offered reader" `Quick
            test_small_failed_payloads_remain_retrievable;
          test_case "repeated refusals collapse into one digest row" `Quick
            test_failure_digest_dedupes_and_counts;
          test_case "no digest block without refusals" `Quick
            test_no_digest_without_failures;
        ] );
      ( "goal titles",
        [
          test_case "summaries render titles, unresolved ids stay bare" `Quick
            test_goal_summaries_render_titles;
          test_case "the heading counts what the block lists" `Quick
            test_goal_heading_counts_what_the_block_lists;
          test_case "no summaries renders no layer" `Quick
            test_no_summaries_renders_no_goal_layer;
        ] );
      ( "previous turn stop reaches the next prompt",
        [
          test_case "a repeated tool call is named with its count" `Quick
            test_repeated_tool_call_stop_is_named_in_the_next_prompt;
          test_case "repeated assistant text is named with its count" `Quick
            test_repeated_text_stop_is_named_in_the_next_prompt;
          test_case "no previous stop renders no line" `Quick
            test_no_previous_stop_renders_no_line;
        ] );
      ( "backlog task identities",
        [
          test_case "parsed once per physical task list" `Quick
            test_task_identities_are_parsed_once_per_backlog_list;
        ] );
    ]
