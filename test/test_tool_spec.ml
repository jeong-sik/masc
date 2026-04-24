(** Tests for Tool_spec — unified tool specification and registration. *)

module Tool_spec = Masc_mcp.Tool_spec
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_catalog = Masc_mcp.Tool_catalog

(** Helper: minimal input_schema for test tools. *)
let empty_schema = `Assoc [ ("type", `String "object") ]

let () =
  let open Alcotest in
  run "Tool_spec"
    [
      ( "create",
        [
          test_case "create with required args only" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_required"
                ~description:"test required only"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            check string "name" "__test_spec_required" spec.name;
            check string "description" "test required only" spec.description;
            check bool "is_read_only default" false spec.is_read_only;
            check bool "requires_join default" false spec.requires_join;
            check bool "is_destructive default" false spec.is_destructive;
            check bool "is_idempotent default" false spec.is_idempotent;
            check bool "allow_direct_call default" false spec.allow_direct_call_when_hidden;
            check bool "required_permission default" true
              (Option.is_none spec.required_permission);
            check bool "canonical_name default" true (Option.is_none spec.canonical_name);
            check bool "replacement default" true (Option.is_none spec.replacement);
            check bool "reason default" true (Option.is_none spec.reason);
            check bool "effect_domain default" true
              (Option.is_none spec.effect_domain);
            check bool "requires_actor_binding default" true
              (Option.is_none spec.requires_actor_binding);
            check bool "title default" true (Option.is_none spec.title));
          test_case "create with optional args" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_optional"
                ~description:"test optional"
                ~module_tag:Tool_dispatch.Mod_compact
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~is_read_only:true
                ~is_idempotent:true
                ~visibility:Tool_catalog.Hidden
                ~required_permission:Types.CanAdmin
                ~effect_domain:Tool_catalog.Masc_coordination
                ~requires_actor_binding:true
                ~reason:"hidden for test"
                ~title:"Test Tool"
                ()
            in
            check bool "is_read_only" true spec.is_read_only;
            check bool "is_idempotent" true spec.is_idempotent;
            check bool "required_permission" true
              (spec.required_permission = Some Types.CanAdmin);
            check bool "effect_domain" true
              (spec.effect_domain = Some Tool_catalog.Masc_coordination);
            check bool "requires_actor_binding" true
              (spec.requires_actor_binding = Some true);
            check bool "reason present" true (Option.is_some spec.reason);
            check bool "title present" true (Option.is_some spec.title));
        ] );
      ( "register",
        [
          test_case "register populates tag_registry" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_tag_reg"
                ~description:"tag registry test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            check bool "tag registered" true
              (Option.is_some (Tool_dispatch.lookup_tag "__test_spec_tag_reg"));
            let tag = Option.get (Tool_dispatch.lookup_tag "__test_spec_tag_reg") in
            check bool "tag is Mod_misc" true
              (tag = Tool_dispatch.Mod_misc));
          test_case "register populates schema_registry" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_schema_reg"
                ~description:"schema registry test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            check bool "schema registered" true
              (Option.is_some (Tool_dispatch.lookup_schema "__test_spec_schema_reg")));
          test_case "register sets read_only" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_ro"
                ~description:"read only test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~is_read_only:true
                ()
            in
            Tool_spec.register spec;
            check bool "is_read_only" true
              (Tool_dispatch.is_read_only "__test_spec_ro"));
          test_case "register non-read_only stays out of set" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_rw"
                ~description:"read-write test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            check bool "not read_only" false
              (Tool_dispatch.is_read_only "__test_spec_rw"));
          test_case "register sets requires_join" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_join"
                ~description:"join test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~requires_join:true
                ()
            in
            Tool_spec.register spec;
            check bool "is_join_required" true
              (Tool_dispatch.is_join_required "__test_spec_join"));
          test_case "register sets catalog metadata" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_catalog"
                ~description:"catalog test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~is_destructive:true
                ~required_permission:Types.CanAdmin
                ~effect_domain:Tool_catalog.Main_worktree_write
                ~requires_actor_binding:true
                ~visibility:Tool_catalog.Hidden
                ~reason:"test hidden"
                ()
            in
            Tool_spec.register spec;
            let meta = Tool_catalog.metadata "__test_spec_catalog" in
            check bool "destructive" true (meta.destructive = Some true);
            check bool "required_permission" true
              (meta.required_permission = Some Types.CanAdmin);
            check bool "effect_domain" true
              (meta.effect_domain = Some Tool_catalog.Main_worktree_write);
            check bool "requires_actor_binding" true
              (meta.requires_actor_binding = Some true);
            check bool "hidden" true (meta.visibility = Tool_catalog.Hidden);
            check bool "reason" true (meta.reason = Some "test hidden"));
          test_case "empty name rejected" `Quick (fun () ->
            check_raises "invalid_arg"
              (Invalid_argument "Tool_spec.register: name must not be empty")
              (fun () ->
                Tool_spec.register
                  (Tool_spec.create
                     ~name:""
                     ~description:"bad"
                     ~module_tag:Tool_dispatch.Mod_misc
                     ~input_schema:empty_schema
                     ~handler_binding:Tag_dispatch
                     ())));
        ] );
      ( "register_all",
        [
          test_case "register_all bulk registers" `Quick (fun () ->
            let specs =
              List.map
                (fun name ->
                  Tool_spec.create
                    ~name
                    ~description:("bulk " ^ name)
                    ~module_tag:Tool_dispatch.Mod_misc
                    ~input_schema:empty_schema
                    ~handler_binding:Tag_dispatch
                    ())
                [ "__test_spec_bulk_a"; "__test_spec_bulk_b"; "__test_spec_bulk_c" ]
            in
            Tool_spec.register_all specs;
            List.iter
              (fun name ->
                check bool (name ^ " in tag_registry") true
                  (Option.is_some (Tool_dispatch.lookup_tag name)))
              [ "__test_spec_bulk_a"; "__test_spec_bulk_b"; "__test_spec_bulk_c" ]);
        ] );
      ( "to_tool_schema",
        [
          test_case "to_tool_schema converts correctly" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_schema_conv"
                ~description:"schema conv test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            let schema = Tool_spec.to_tool_schema spec in
            check string "name" "__test_spec_schema_conv" schema.Types.name;
            check string "description" "schema conv test" schema.description);
        ] );
      ( "tool_catalog_groups",
        [
          test_case "typed tool groups are exposed without string-prefix routing" `Quick
            (fun () ->
              let check_group name expected =
                check (option string) name (Some expected)
                  (Option.map Tool_catalog.tool_group_to_string
                     (Tool_catalog.tool_group name))
              in
              check_group "keeper_board_post" "board";
              check_group "keeper_memory_search" "knowledge";
              check_group "keeper_library_read" "knowledge";
              check_group "keeper_task_claim" "tasks";
              check_group "keeper_voice_speak" "voice";
              check_group "keeper_fs_read" "filesystem";
              check_group "keeper_bash" "filesystem";
              check_group "masc_board_post" "masc_board";
              check_group "masc_keeper_status" "masc_keeper";
              check_group "masc_plan_get" "masc_plan";
              check_group "masc_worktree_list" "masc_worktree";
              check_group "masc_code_write" "masc_code";
              check_group "masc_autoresearch_status" "masc_autoresearch";
              check_group "masc_agents" "masc_agent";
              check_group "masc_status" "masc_core";
              check (option string) "unknown" None
                (Option.map Tool_catalog.tool_group_to_string
                   (Tool_catalog.tool_group "__unknown_tool")));
          test_case "metadata fields include typed tool group" `Quick (fun () ->
            let fields = Tool_catalog.metadata_to_fields "keeper_board_post" in
            check bool "toolGroup=board" true
              (List.mem ("toolGroup", `String "board") fields);
            check bool "unknown has no toolGroup" false
              (Tool_catalog.metadata_to_fields "__unknown_tool"
              |> List.exists (fun (key, _) -> String.equal key "toolGroup")));
        ] );
      ( "verify_handler_coverage",
        [
          test_case "Tag_dispatch binding not in verify missing" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_tag_dispatch"
                ~description:"tag dispatch test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            let missing = Tool_spec.verify_handler_coverage () in
            check bool "Tag_dispatch not in missing" false
              (List.mem "__test_spec_tag_dispatch" missing));
          test_case "Match_chain binding not in verify missing" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_match_chain"
                ~description:"match chain test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Match_chain
                ()
            in
            Tool_spec.register spec;
            let missing = Tool_spec.verify_handler_coverage () in
            check bool "Match_chain not in missing" false
              (List.mem "__test_spec_match_chain" missing));
          test_case "Direct binding registers handler" `Quick (fun () ->
            let name = "__test_spec_direct_handler" in
            let spec =
              Tool_spec.create
                ~name
                ~description:"direct handler test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:(Direct (fun ~name:_ ~args:_ -> Some (true, "ok")))
                ()
            in
            Tool_spec.register spec;
            check bool "handler registered in Tool_dispatch" true
              (Tool_dispatch.is_registered name);
            let missing = Tool_spec.verify_handler_coverage () in
            check bool "not in missing" false
              (List.mem name missing));
        ] );
    ]
