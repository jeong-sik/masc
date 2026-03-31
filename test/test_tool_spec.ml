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
                ()
            in
            check string "name" "__test_spec_required" spec.name;
            check string "description" "test required only" spec.description;
            check bool "is_read_only default" false spec.is_read_only;
            check bool "requires_join default" false spec.requires_join;
            check bool "is_destructive default" false spec.is_destructive;
            check bool "is_idempotent default" false spec.is_idempotent;
            check bool "allow_direct_call default" false spec.allow_direct_call_when_hidden;
            check bool "canonical_name default" true (Option.is_none spec.canonical_name);
            check bool "replacement default" true (Option.is_none spec.replacement);
            check bool "reason default" true (Option.is_none spec.reason);
            check bool "title default" true (Option.is_none spec.title));
          test_case "create with optional args" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_optional"
                ~description:"test optional"
                ~module_tag:Tool_dispatch.Mod_compact
                ~input_schema:empty_schema
                ~is_read_only:true
                ~is_idempotent:true
                ~visibility:Tool_catalog.Hidden
                ~reason:"hidden for test"
                ~title:"Test Tool"
                ()
            in
            check bool "is_read_only" true spec.is_read_only;
            check bool "is_idempotent" true spec.is_idempotent;
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
                ~is_destructive:true
                ~visibility:Tool_catalog.Hidden
                ~reason:"test hidden"
                ()
            in
            Tool_spec.register spec;
            let meta = Tool_catalog.metadata "__test_spec_catalog" in
            check bool "destructive" true (meta.destructive = Some true);
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
                ()
            in
            let schema = Tool_spec.to_tool_schema spec in
            check string "name" "__test_spec_schema_conv" schema.Types.name;
            check string "description" "schema conv test" schema.description);
        ] );
      ( "verify_handler_coverage",
        [
          test_case "spec without handler appears in missing" `Quick (fun () ->
            let spec =
              Tool_spec.create
                ~name:"__test_spec_no_handler"
                ~description:"no handler test"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ()
            in
            Tool_spec.register spec;
            let missing = Tool_spec.verify_handler_coverage () in
            check bool "missing contains our tool" true
              (List.mem "__test_spec_no_handler" missing));
          test_case "spec with handler not in missing" `Quick (fun () ->
            let name = "__test_spec_has_handler" in
            let spec =
              Tool_spec.create
                ~name
                ~description:"has handler"
                ~module_tag:Tool_dispatch.Mod_misc
                ~input_schema:empty_schema
                ()
            in
            Tool_spec.register spec;
            Tool_dispatch.register ~tool_name:name
              ~handler:(fun ~name:_ ~args:_ -> Some (true, "ok"));
            let missing = Tool_spec.verify_handler_coverage () in
            check bool "not in missing" false
              (List.mem name missing));
        ] );
    ]
