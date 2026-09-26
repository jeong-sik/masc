(** The [skill_catalog] section of [/health?full=1] (#39269).

    A rejected Skill configuration drops every source, so every Keeper sees no
    Skills, and before this [/health] stayed ok. These cases pin that the
    section grades it, carries each diagnostic, and reaches the operator
    rollup. *)

open Alcotest
module Health = Server_skill_catalog_health

(* The live value that emptied the catalog: above the inline tool-result
   boundary a resource is returned through. *)
let over_boundary_config = "[skills]\nresource-read-max-bytes = 65536\n"

let rejected_snapshot () =
  match Skill_source_config.parse_text over_boundary_config with
  | Ok _ -> fail "a bound above the inline boundary parsed"
  | Error diagnostics ->
    ( diagnostics
    , Skill_catalog_snapshot.config_rejected
        ~source_text:over_boundary_config
        ~diagnostics )
;;

(* Every configured source is observed missing, which is what a fresh
   workspace without the source directories publishes. *)
let configured_snapshot
      ?(observation = Skill_catalog_snapshot.Source_missing { resolved_path = "/fixture/missing" })
      config_text =
  match Skill_source_config.parse_text config_text with
  | Error _ -> failf "fixture config %S was rejected" config_text
  | Ok config ->
    let scans =
      List.map
        (fun source ->
           let resolved = Skill_source_config.resolve ~base_path:"/fixture" ~user_home:None source in
           { Skill_catalog_snapshot.source = resolved
           ; observation
           ; candidates = []
           })
        config.Skill_source_config.sources
    in
    (match Skill_catalog_snapshot.configured ~config scans with
     | Ok snapshot -> snapshot
     | Error _ -> failf "fixture config %S did not build a snapshot" config_text)
;;

let config_path = "/tmp/live/runtime.toml"

let ready snapshot =
  Health.to_yojson (Ok (Server_skill_snapshot_runtime.Ready { snapshot; config_path }))
;;

let member = Yojson.Safe.Util.member
let status json = member "status" json |> Yojson.Safe.Util.to_string
let config_state json = member "config_state" json |> Yojson.Safe.Util.to_string
let action_required json = member "operator_action_required" json |> Yojson.Safe.Util.to_bool

let strings name json =
  member name json |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string
;;

let rollup sections =
  Server_health_rollup.operator_summary
    ~sections
    ~runtime_startup_degradation:(`Assoc [])
    ~keeper_config_schema_status:"ok"
    ~keeper_config_schema_blocking:false
    ~keeper_config_schema_terminal_reason:""
    ~keeper_config_operator_action_required:false
    ~lazy_task_boot_guard_fires_total:0
;;

let test_rejected_config_degrades_with_each_diagnostic () =
  let diagnostics, snapshot = rejected_snapshot () in
  let json = ready snapshot in
  check string "rejected config degrades" "degraded" (status json);
  check string "the section names the config state" "rejected" (config_state json);
  check bool "rejected config needs an operator" true (action_required json);
  let reasons = strings "operator_action_reasons" json in
  check int "one reason per diagnostic" (List.length diagnostics) (List.length reasons);
  List.iter2
    (fun diagnostic reason ->
       (* The boot WARN and the save-path 400 print this same line. *)
       let line = Skill_source_config.rejection_message ~config_path [ diagnostic ] in
       check bool ("the reason carries " ^ line) true
         (String_util.contains_substring reason line))
    diagnostics
    reasons;
  check (list string) "the same lines explain the grade" reasons
    (strings "status_reasons" json)
;;

let test_unreadable_config_degrades_with_its_detail () =
  let detail = "Skill snapshot source/config association failed" in
  let json = ready (Skill_catalog_snapshot.config_unreadable ~detail) in
  check string "unreadable config degrades" "degraded" (status json);
  check string "the section names the config state" "unreadable" (config_state json);
  check bool "unreadable config needs an operator" true (action_required json);
  match strings "operator_action_reasons" json with
  | [ reason ] ->
    check bool "the reason carries the detail" true
      (String_util.contains_substring reason detail);
    check bool "the reason names the file" true
      (String_util.contains_substring reason config_path)
  | reasons -> failf "expected one reason, got %d" (List.length reasons)
;;

let test_configured_catalog_is_ok () =
  let json =
    ready (configured_snapshot "[skills]\nresource-read-max-bytes = 16384\n")
  in
  check string "configured catalog is ok" "ok" (status json);
  check string "the section names the config state" "configured" (config_state json);
  check bool "configured catalog needs nobody" false (action_required json);
  check (list string) "configured catalog has no reason" []
    (strings "operator_action_reasons" json)
;;

(* runtime.toml without a [skills] table configures an empty catalog. That is
   a legitimate choice, not a fault. *)
let test_absent_skills_table_is_ok () =
  let json = ready (configured_snapshot "") in
  check string "no [skills] table is ok" "ok" (status json);
  check bool "no [skills] table needs nobody" false (action_required json)
;;

let int_member name json = member name json |> Yojson.Safe.Util.to_int

(* The counts say what the published snapshot holds and leave the grade to the
   config state: a configured catalog whose only source is missing is ok. *)
let test_counts_describe_the_snapshot_without_moving_the_grade () =
  let json =
    ready
      (configured_snapshot
         "[skills]\nresource-read-max-bytes = 16384\n\n[[skills.sources]]\nid = \"project\"\n\
          anchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-only\"\n")
  in
  check string "a missing source leaves the grade ok" "ok" (status json);
  check string "the path the snapshot was built from" config_path
    (member "config_path" json |> Yojson.Safe.Util.to_string);
  check int "no Skills" 0 (int_member "skills" json);
  check int "no rejections" 0 (int_member "rejections" json);
  let sources = member "sources" json in
  check (list int) "one source, observed missing" [ 0; 1; 0; 0; 0 ]
    (List.map
       (fun name -> int_member name sources)
       [ "ready"; "missing"; "not_directory"; "unavailable"; "unresolved" ])
;;

let test_rejected_catalog_counts_nothing () =
  let _, snapshot = rejected_snapshot () in
  let json = ready snapshot in
  check int "a rejected catalog holds no Skills" 0 (int_member "skills" json);
  check int "and no sources" 0 (int_member "ready" (member "sources" json))
;;

let test_unavailable_source_degrades_section_and_rollup () =
  let detail = "EACCES: synthetic directory read denied" in
  let snapshot = configured_snapshot
    ~observation:(Source_unavailable
      { resolved_path = "/fixture/skills"; operation = Read_source_directory; detail })
    "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"project\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
  in
  let json = ready snapshot in
  check string "failed source degrades a valid configuration" "degraded" (status json);
  check bool "source needs an operator" true (action_required json);
  let reasons = strings "status_reasons" json in
  check int "one failed source" 1 (List.length reasons);
  List.iter (fun expected ->
    check bool ("source reason retains " ^ expected) true
      (List.exists (fun reason -> String_util.contains_substring reason expected) reasons))
    [ "project"; "/fixture/skills"; "read source directory"; detail ];
  let summary = rollup [ "skill_catalog", json ] in
  check string "source failure reaches overall health" "degraded"
    summary.Server_health_rollup.overall_status;
  check bool "rollup requires operator action" true summary.operator_action_required
;;

(* The timed-out fallback and the no-server-state case keep the schema, so a
   reader can tell the section from a missing one. *)
let test_placeholder_keeps_the_schema () =
  let json = Health.placeholder ~component_timed_out:true ~status:"unavailable" () in
  check string "the placeholder keeps the schema" "masc.skill_catalog.v1"
    (member "schema" json |> Yojson.Safe.Util.to_string);
  check bool "the placeholder asks nothing of the operator" false (action_required json)
;;

let test_unpublished_catalog_needs_no_answer_here () =
  let json = Health.to_yojson (Ok Server_skill_snapshot_runtime.Uninitialized) in
  check string "unpublished catalog is not ready" "snapshot_not_ready" (status json);
  check bool "unpublished catalog asks nothing of the operator" false
    (action_required json)
;;

let test_rollup_raises_operator_action_from_the_section () =
  let _, snapshot = rejected_snapshot () in
  let json = ready snapshot in
  let summary = rollup [ "skill_catalog", json ] in
  check string "the section moves overall_status" "degraded"
    summary.Server_health_rollup.overall_status;
  check bool "the section raises operator_action_required" true
    summary.operator_action_required;
  check (list string) "each reason arrives prefixed with the section"
    (List.map (fun reason -> "skill_catalog:" ^ reason)
       (strings "operator_action_reasons" json))
    summary.operator_action_reasons
;;

let test_rollup_is_quiet_for_a_configured_catalog () =
  let json =
    ready (configured_snapshot "[skills]\nresource-read-max-bytes = 16384\n")
  in
  let summary = rollup [ "skill_catalog", json ] in
  check string "a configured catalog leaves the status ok" "ok"
    summary.Server_health_rollup.overall_status;
  check bool "a configured catalog raises nothing" false
    summary.operator_action_required;
  check (list string) "a configured catalog leaves no line" []
    summary.overall_status_reasons
;;

let () =
  run
    "server_skill_catalog_health"
    [ ( "section"
      , [ test_case "rejected config degrades with each diagnostic" `Quick
            test_rejected_config_degrades_with_each_diagnostic
        ; test_case "unavailable source degrades section and rollup" `Quick
            test_unavailable_source_degrades_section_and_rollup
        ; test_case "counts describe the snapshot without moving the grade" `Quick
            test_counts_describe_the_snapshot_without_moving_the_grade
        ; test_case "rejected catalog counts nothing" `Quick
            test_rejected_catalog_counts_nothing
        ; test_case "placeholder keeps the schema" `Quick test_placeholder_keeps_the_schema
        ; test_case "unreadable config degrades with its detail" `Quick
            test_unreadable_config_degrades_with_its_detail
        ; test_case "configured catalog is ok" `Quick test_configured_catalog_is_ok
        ; test_case "absent skills table is ok" `Quick test_absent_skills_table_is_ok
        ; test_case "unpublished catalog needs no answer here" `Quick
            test_unpublished_catalog_needs_no_answer_here
        ] )
    ; ( "rollup"
      , [ test_case "rollup raises operator action from the section" `Quick
            test_rollup_raises_operator_action_from_the_section
        ; test_case "rollup is quiet for a configured catalog" `Quick
            test_rollup_is_quiet_for_a_configured_catalog
        ] )
    ]
;;
