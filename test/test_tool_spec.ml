module Types = Masc_domain

(** Tests for Tool_spec — unified tool specification and registration. *)

module Tool_spec = Tool_spec
module Tool_dispatch = Tool_dispatch
module Tool_catalog = Tool_catalog
module Tool_capability = Tool_capability

(** Helper: minimal input_schema for test tools. *)
let empty_schema = `Assoc [ ("type", `String "object") ]

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

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
            check bool "requires_actor_binding default" true
              (Option.is_none spec.requires_actor_binding);
            check bool "mcp_context_required default" false
              spec.mcp_context_required;
            check bool "is_destructive default" false spec.is_destructive;
            check bool "is_idempotent default" false spec.is_idempotent;
            check bool "allow_direct_call default" false spec.allow_direct_call_when_hidden;
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
                ~effect_domain:Tool_catalog.Masc_workspace
                ~requires_actor_binding:true
                ~reason:"hidden for test"
                ~title:"Test Tool"
                ()
            in
            check bool "is_read_only" true spec.is_read_only;
            check bool "is_idempotent" true spec.is_idempotent;
            check bool "effect_domain" true
              (spec.effect_domain = Some Tool_catalog.Masc_workspace);
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
          test_case "register sets read_only metadata" `Quick (fun () ->
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
              (Tool_capability.has Tool_capability.Read_only "__test_spec_ro"));
          test_case "register non-read_only stays mutable" `Quick (fun () ->
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
              (Tool_capability.has Tool_capability.Read_only "__test_spec_rw"));
          test_case "register sets actor-binding metadata" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_actor_binding"
                ~description:"actor binding test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~requires_actor_binding:true
                ()
            in
            Tool_spec.register spec;
            check bool "catalog requires_actor_binding" true
              (Tool_catalog.requires_actor_binding "__test_spec_actor_binding");
            let meta = Tool_catalog.metadata "__test_spec_actor_binding" in
            check bool "requires_actor_binding metadata" true
              (meta.requires_actor_binding = Some true));
          test_case "register sets mcp context required" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_mcp_context"
                ~description:"mcp context test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~mcp_context_required:true
                ()
            in
            Tool_spec.register spec;
            check bool "is_mcp_context_required" true
              (Tool_capability.has Tool_capability.Mcp_context_required "__test_spec_mcp_context");
            let meta = Tool_catalog.metadata "__test_spec_mcp_context" in
            check bool "catalog mcp_context_required" true
              (meta.mcp_context_required = Some true));
          test_case "register sets catalog metadata" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_catalog"
                ~description:"catalog test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ~is_destructive:true
                ~effect_domain:Tool_catalog.Host_repo_write
                ~requires_actor_binding:true
                ~required_permission:Masc_domain.CanAdmin
                ~visibility:Tool_catalog.Hidden
                ~reason:"test hidden"
                ()
            in
            Tool_spec.register spec;
            let meta = Tool_catalog.metadata "__test_spec_catalog" in
            check bool "destructive" true (meta.destructive = Some true);
            check bool "effect_domain" true
              (meta.effect_domain = Some Tool_catalog.Host_repo_write);
            check bool "requires_actor_binding" true
              (meta.requires_actor_binding = Some true);
            check bool "required_permission" true
              (meta.required_permission = Some Masc_domain.CanAdmin);
            check bool "hidden" true (meta.visibility = Tool_catalog.Hidden);
            check bool "reason" true (meta.reason = Some "test hidden"));
          test_case "register preserves catalog actor binding by default" `Quick (fun () ->
            let name = "__test_spec_preserve_actor" in
            let existing = Tool_catalog.metadata name in
            Tool_catalog.register_metadata name
              { existing with
                requires_actor_binding = Some true;
                effect_domain = Some Tool_catalog.Masc_workspace };
            let spec =
              Tool_spec.create
                ~name
                ~description:"preserve actor binding"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            let meta = Tool_catalog.metadata name in
            check bool "requires_actor_binding preserved" true
              (meta.requires_actor_binding = Some true));
          test_case "register preserves catalog permission by default" `Quick (fun () ->
            let name = "__test_spec_preserve_permission" in
            let existing = Tool_catalog.metadata name in
            Tool_catalog.register_metadata name
              { existing with required_permission = Some Masc_domain.CanAdmin };
            let spec =
              Tool_spec.create
                ~name
                ~description:"preserve required permission"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:Tag_dispatch
                ()
            in
            Tool_spec.register spec;
            let meta = Tool_catalog.metadata name in
            check bool "required_permission preserved" true
              (meta.required_permission = Some Masc_domain.CanAdmin));
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
            check string "name" "__test_spec_schema_conv" schema.Masc_domain.name;
            check string "description" "schema conv test" schema.description);
        ] );
      (* The "tool_catalog_groups" test group was removed in the surface-cut
         refactor: it exercised the deleted [Tool_catalog.tool_group] display
         classifier (and was already failing on base — it asserted richer
         categories the classifier never produced). *)
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
          test_case "Direct binding registers handler" `Quick (fun () ->
            let name = "__test_spec_direct_handler" in
            let spec =
              Tool_spec.create
                ~name
                ~description:"direct handler test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ~handler_binding:(Direct (fun ~name:_ ~args:_ -> Some (tool_ok "ok")))
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
