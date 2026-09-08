open Alcotest
module Surface = Masc.Standalone_skill_tools
module Snapshot = Skill_catalog_snapshot
module Service = Skill_catalog_snapshot_service

let get = function Ok value -> value | Error _ -> fail "fixture setup failed"
let write path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_text path (fun channel -> output_string channel text)

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun entry -> remove (Filename.concat path entry));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let document body = "---\nname: evidence-guide\ndescription: Inspect execution evidence\n---\n" ^ body
let config_text =
  "[[skills.sources]]\nid = \"local\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"

let with_workspace f =
  Eio_main.run (fun _ ->
    let root = Filename.temp_dir "standalone-skills" "test" in
    Fs_compat.mkdir_p (Filename.concat root ".masc");
    let workspace = get (Service.workspace_of_base_path ~base_path:root) in
    Fun.protect
      ~finally:(fun () -> Service.retire ~workspace; remove root)
      (fun () -> f root workspace))

let refresh workspace =
  match Service.refresh ~workspace ~user_home:None
          ~read_config:(fun () -> Service.Config_text config_text) with
  | Service.Published snapshot | Service.Unchanged snapshot -> snapshot
  | Service.Workspace_retired -> fail "fixture workspace retired"

let invoke tool id input =
  let invocation = Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:id ~turn:0
      ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1;
                  execution_mode = Agent_core.Tool_contract.Serial }
      ~completion:(Agent_core.Tool.completion tool) in
  tool.Agent_core.Tool.handler (Agent_core.Tool.Execution_env.create ~invocation ()) input

let content = function
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error error -> fail error.Agent_core.Llm_provider.Types.message

let reference snapshot =
  match Snapshot.effective_entries snapshot with
  | [ entry ] -> Snapshot.entry_reference entry
  | _ -> fail "expected one instruction Skill"

let with_file reference file =
  match Skill_reference.to_yojson reference with
  | `Assoc fields -> `Assoc (("file", `String file) :: fields)
  | _ -> fail "reference must be an object"

let test_read_freeze_and_observe () = with_workspace (fun root workspace ->
  let path = Filename.concat root "skills/guide/SKILL.md" in
  write path (document "Read references/proof.md before evaluating the logs.");
  write (Filename.concat root "skills/guide/references/proof.md") "Compare the execution SHA with the requested SHA.";
  let snapshot = refresh workspace in
  let reference = reference snapshot in
  let observed = ref [] in
  let tools = get (Surface.for_workspace
      ~config:(Masc.Workspace.default_config root)
      ~on_result:(fun ~input result -> observed := (input, result) :: !observed) ()) in
  check (list string) "only a read-only Skill tool" [ "keeper_skill" ]
    (List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools);
  let tool = List.hd tools in
  check bool "Available catalog guides selection" true
    (String_util.contains_substring tool.schema.description "evidence-guide");
  let body = invoke tool "read-body" (Skill_reference.to_yojson reference) |> content in
  check string "frozen body" "Read references/proof.md before evaluating the logs." body;
  let resource = invoke tool "read-reference" (with_file reference "references/proof.md") |> content in
  check string "resource served through real reader" "Compare the execution SHA with the requested SHA." resource;
  write path (document "A newly published body.");
  ignore (refresh workspace);
  check string "existing run retains original snapshot" body
    (invoke tool "read-frozen" (Skill_reference.to_yojson reference) |> content);
  check int "every Skill call reaches run observer" 3 (List.length !observed);
  let new_tools = get (Surface.for_workspace ~config:(Masc.Workspace.default_config root) ()) in
  match invoke (List.hd new_tools) "old-revision" (Skill_reference.to_yojson reference) with
  | Error _ -> ()
  | Ok _ -> fail "new run accepted an obsolete exact revision")

let test_resource_boundary () = with_workspace (fun root workspace ->
  write (Filename.concat root "skills/guide/SKILL.md") (document "Inspect evidence.");
  write (Filename.concat root "skills/OUTSIDE.md") "NOT_A_BUNDLED_REFERENCE";
  let snapshot = refresh workspace in
  let tools = Surface.of_snapshot ~config:(Masc.Workspace.default_config root) snapshot in
  match invoke (List.hd tools) "escape" (with_file (reference snapshot) "../OUTSIDE.md") with
  | Error _ -> ()
  | Ok _ -> fail "Skill read escaped its package")

let test_absent_snapshot () = with_workspace (fun root _ ->
  check int "no invented Skill tool before publication" 0
    (List.length (get (Surface.for_workspace ~config:(Masc.Workspace.default_config root) ()))))

let test_workspace_isolation () = with_workspace (fun root workspace ->
  let other_root = Filename.temp_dir "standalone-other-skills" "test" in
  Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () -> remove other_root);
    Fs_compat.mkdir_p (Filename.concat other_root ".masc");
    let other_workspace = get (Service.workspace_of_base_path ~base_path:other_root) in
    Eio.Switch.on_release sw (fun () -> Service.retire ~workspace:other_workspace);
    write (Filename.concat root "skills/guide/SKILL.md")
      (document "Evidence procedure for workspace A.");
    write (Filename.concat other_root "skills/guide/SKILL.md")
      (document "Evidence procedure for workspace B.");
    let snapshot = refresh workspace in
    let other_snapshot = refresh other_workspace in
    let tool = List.hd (get (Surface.for_workspace
        ~config:(Masc.Workspace.default_config root) ())) in
    let other_tool = List.hd (get (Surface.for_workspace
        ~config:(Masc.Workspace.default_config other_root) ())) in
    check string "first workspace reads its own published body"
      "Evidence procedure for workspace A."
      (invoke tool "workspace-a" (Skill_reference.to_yojson (reference snapshot)) |> content);
    check string "second workspace reads its own published body"
      "Evidence procedure for workspace B."
      (invoke other_tool "workspace-b"
         (Skill_reference.to_yojson (reference other_snapshot)) |> content);
    match invoke tool "foreign-revision"
            (Skill_reference.to_yojson (reference other_snapshot)) with
    | Error _ -> ()
    | Ok _ -> fail "first workspace accepted a reference from the second workspace"))

let test_composition_not_available () = with_workspace (fun root workspace ->
  write (Filename.concat root "skills/guide/SKILL.md")
    (document
       "```toml composition\n[[compositions]]\nname = \"evidence-guide\"\ndescription = \"Inspect execution evidence\"\nexecution = \"inline\"\n[[compositions.nodes]]\nid = \"clock\"\ntool = \"keeper_time_now\"\n[compositions.nodes.input]\nkind = \"literal\"\nvalue = {}\n```");
  let snapshot = refresh workspace in
  let catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot snapshot in
  check int "composition fixture projects without errors" 0 (List.length diagnostics);
  check int "catalog contains a valid executable composition" 1
    (List.length (Masc.Keeper_skill_catalog.compositions catalog));
  check int "composition-only catalog exposes no standalone tools" 0
    (List.length (get (Surface.for_workspace ~config:(Masc.Workspace.default_config root) ()))))

let () = run "standalone Skill tools"
  [ "read-only instruction workflow",
    [ test_case "body, resource, frozen snapshot and observations" `Quick test_read_freeze_and_observe
    ; test_case "package traversal refused" `Quick test_resource_boundary
    ; test_case "unpublished catalog exposes no tools" `Quick test_absent_snapshot
    ; test_case "published workspaces keep their own Skill bodies" `Quick test_workspace_isolation
    ; test_case "valid composition exposes no standalone tools" `Quick test_composition_not_available ] ]
