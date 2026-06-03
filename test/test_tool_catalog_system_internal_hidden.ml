open Alcotest

(** Surface-cut behavioral guard for system-internal tool hiding.

    The [System_internal] surface variant was deleted and its 13-tool list
    re-homed to [Tool_catalog_surfaces.system_internal_hidden] (a flat
    visibility list). These tools must remain:
      - absent from the public Full profile schema set, AND
      - reported as Hidden by [Tool_catalog.metadata], even when they also
        carry explicit Default-visibility metadata (the dual-status override).

    The second assertion is the load-bearing one: the Full-profile filter and
    the metadata visibility override are two different code paths. A test that
    only checks "absent from Full" would pass even if the metadata override
    silently broke and leaked an internal tool into [is_visible] / OAS /
    capability listings. *)

module Tool_catalog = Tool_catalog
module Tool_catalog_surfaces = Tool_catalog_surfaces
module TP = Masc.Mcp_server_eio_tool_profile

let system_internal_hidden = Tool_catalog_surfaces.system_internal_hidden

(* A tool that is BOTH system-internal-hidden AND carries explicit
   read_state_tool (Default visibility) metadata in tool_catalog.ml. The
   metadata override must force it Hidden. *)
let dual_status_tool = "masc_get_metrics"

let full_profile_tool_names () =
  let state = Masc.Mcp_server.create_state ~base_path:"/tmp/masc-surface-cut-test" in
  TP.tool_schemas_for_profile state TP.Full
  |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)

let test_hidden_set_has_thirteen () =
  check int "system_internal_hidden has 13 entries" 13
    (List.length system_internal_hidden)

let test_dual_status_tool_is_in_hidden_set () =
  check bool (dual_status_tool ^ " is system-internal-hidden") true
    (Tool_catalog_surfaces.is_system_internal_hidden dual_status_tool)

let test_hidden_tools_absent_from_full_profile () =
  let full = full_profile_tool_names () in
  List.iter
    (fun name ->
      check bool (name ^ " absent from Full profile") false (List.mem name full))
    system_internal_hidden

let test_dual_status_metadata_visibility_hidden () =
  (* The override path: even though masc_get_metrics has explicit
     read_state_tool (Default) metadata, system-internal membership must
     force visibility = Hidden. *)
  let meta = Tool_catalog.metadata dual_status_tool in
  (match meta.Tool_catalog.visibility with
   | Tool_catalog.Hidden -> ()
   | Tool_catalog.Default ->
     fail (dual_status_tool ^ " metadata visibility must be Hidden (override lost)"));
  check bool (dual_status_tool ^ " allow_direct_call_when_hidden") true
    meta.Tool_catalog.allow_direct_call_when_hidden

let test_dual_status_is_visible_false () =
  (* The consumer-visible consequence of the override: a default tools/list
     (include_hidden=false) must not surface the tool. *)
  check bool (dual_status_tool ^ " not visible without include_hidden") false
    (Tool_catalog.is_visible dual_status_tool);
  check bool (dual_status_tool ^ " visible with include_hidden") true
    (Tool_catalog.is_visible ~include_hidden:true dual_status_tool)

let test_all_hidden_tools_metadata_hidden () =
  (* No system-internal tool may report Default visibility. *)
  List.iter
    (fun name ->
      let meta = Tool_catalog.metadata name in
      match meta.Tool_catalog.visibility with
      | Tool_catalog.Hidden -> ()
      | Tool_catalog.Default ->
        fail (name ^ " metadata visibility must be Hidden"))
    system_internal_hidden

let () =
  run "tool_catalog_system_internal_hidden"
    [ ( "hidden-list"
      , [ test_case "13 entries" `Quick test_hidden_set_has_thirteen
        ; test_case "dual-status tool in set" `Quick test_dual_status_tool_is_in_hidden_set
        ] )
    ; ( "full-profile"
      , [ test_case "13 absent from Full" `Quick test_hidden_tools_absent_from_full_profile
        ] )
    ; ( "metadata-override"
      , [ test_case "dual-status visibility Hidden" `Quick
            test_dual_status_metadata_visibility_hidden
        ; test_case "dual-status is_visible false" `Quick test_dual_status_is_visible_false
        ; test_case "all 13 metadata Hidden" `Quick test_all_hidden_tools_metadata_hidden
        ] )
    ]
