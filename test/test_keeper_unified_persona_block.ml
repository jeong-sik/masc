(** test_keeper_unified_persona_block — D-11.

    The unified (autonomous) lane shipped without persona injection: the
    system prompt's identity was the one-line header while only the chat
    lane rendered a [<persona>] block, so a keeper had a personality only
    when spoken to. These tests pin the repaired contract: the unified
    system prompt carries the same XML-escaped [<persona>] block the chat
    lane uses, loaded from [personas/<name>/AGENT.md], and omits the block
    entirely when no persona text exists. *)

open Alcotest
module WO = Masc.Keeper_world_observation

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc.Prompt_defaults.init ()

let base_observation : WO.world_observation =
  {
    pending_messages = [];
    pending_board_events = [];
    idle_seconds = 0;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_updated_since_last_scheduled_autonomous = false;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
  }

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("test-trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let contains ~affix s =
  let n = String.length affix and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = affix || go (i + 1)) in
  n = 0 || go 0

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)

let rec rm_rf path =
  try
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  with _ -> ()

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_config_dir f =
  let base = Filename.temp_file "unified-persona-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let config_dir = Filename.concat base ".masc/config" in
  mkdir_p config_dir;
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f ~config_dir)

let test_persona_reaches_unified_system_prompt () =
  with_config_dir @@ fun ~config_dir ->
  let persona_dir = Filename.concat config_dir "personas/test-keeper" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "AGENT.md")
    "집요하고 직설적. 근본 원인을 잡을 때까지 <blame>을 판다.";
  let system_prompt, _user =
    Masc.Keeper_unified_prompt.build_prompt ~meta:(make_meta "test-keeper")
      ~base_path:"/tmp" ~observation:base_observation ()
  in
  check bool "persona block present" true
    (contains ~affix:"<persona>" system_prompt);
  check bool "persona text present" true
    (contains ~affix:"집요하고 직설적" system_prompt);
  check bool "persona text is XML-escaped (chat-lane parity)" true
    (contains ~affix:"&lt;blame&gt;" system_prompt);
  check bool "raw angle-bracket payload does not survive" false
    (contains ~affix:"<blame>" system_prompt)

let test_no_persona_file_means_no_block () =
  with_config_dir @@ fun ~config_dir:_ ->
  let system_prompt, _user =
    Masc.Keeper_unified_prompt.build_prompt ~meta:(make_meta "test-keeper")
      ~base_path:"/tmp" ~observation:base_observation ()
  in
  check bool "no persona block without persona text" false
    (contains ~affix:"<persona>" system_prompt)

(* Pins the identity → persona → shared-body ordering the template
   promises, so a template refactor cannot silently reorder the block. *)
let test_persona_sits_between_identity_and_shared_body () =
  with_config_dir @@ fun ~config_dir ->
  let persona_dir = Filename.concat config_dir "personas/test-keeper" in
  mkdir_p persona_dir;
  write_file (Filename.concat persona_dir "AGENT.md") "차분하고 꼼꼼함.";
  let system_prompt, _user =
    Masc.Keeper_unified_prompt.build_prompt ~meta:(make_meta "test-keeper")
      ~base_path:"/tmp" ~observation:base_observation ()
  in
  let index_of ~affix =
    let n = String.length affix and m = String.length system_prompt in
    let rec go i =
      if i + n > m then
        failwith (Printf.sprintf "affix %S not found in system prompt" affix)
      else if String.sub system_prompt i n = affix then i
      else go (i + 1)
    in
    go 0
  in
  let identity = index_of ~affix:"You are test-keeper" in
  let persona = index_of ~affix:"<persona>" in
  let shared_body = index_of ~affix:"Primary goal" in
  check bool "identity precedes persona" true (identity < persona);
  check bool "persona precedes the shared body" true (persona < shared_body)

let () =
  Alcotest.run "keeper_unified_persona_block"
    [
      ( "d11",
        [
          test_case "persona reaches the unified system prompt" `Quick
            test_persona_reaches_unified_system_prompt;
          test_case "no persona file leaves no empty block" `Quick
            test_no_persona_file_means_no_block;
          test_case "persona sits between identity and shared body" `Quick
            test_persona_sits_between_identity_and_shared_body;
        ] );
    ]
