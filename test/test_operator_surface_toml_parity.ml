(** What the published surface says: which tools the operator surface declares, and three invariants.

    The descriptions and input schemas this suite also pinned were literals
    read off the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself, so the
    only thing it could report was that someone edited a sentence. Those cases
    are gone; every case that stays reads the published value. *)

open Alcotest
(* Each pair binds a name to the value the module exposes under it, so a value
   repointed at another declaration -- or two values swapped -- fails here. A
   lookup that went to the file, or to the name the loaded schema carries,
   would pass in both cases: the file still says the expected thing, and a swap
   leaves both names present. *)
let bindings : (string * Masc_domain.tool_schema) list =
  let open Tool_schemas_operator_surface in
  [ "masc_broadcast", broadcast
  ; "masc_config", config
  ; "masc_dashboard", dashboard
  ; "masc_gc", gc
  ; "masc_keeper_waiting_inventory", keeper_waiting_inventory
  ; "masc_messages", messages
  ; "masc_pause", pause
  ; "masc_pause_status", pause_status
  ; "masc_plan_clear_task", plan_clear_task
  ; "masc_plan_get_task", plan_get_task
  ; "masc_plan_set_task", plan_set_task
  ; "masc_resume", resume
  ; "masc_start", start
  ; "masc_tool_help", tool_help
  ]
;;

let loaded name : Masc_domain.tool_schema =
  match List.assoc_opt name bindings with
  | Some schema -> schema
  | None -> failwith (name ^ " is not bound in Tool_schemas_operator_surface")
;;

(* name, description, input_schema (keys sorted) *)
let expected =
  [ "masc_broadcast"
  ; "masc_config"
  ; "masc_dashboard"
  ; "masc_gc"
  ; "masc_keeper_waiting_inventory"
  ; "masc_messages"
  ; "masc_pause"
  ; "masc_pause_status"
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_plan_set_task"
  ; "masc_resume"
  ; "masc_start"
  ; "masc_tool_help"
  ]
;;

let test_every_tool_the_generator_owned_is_declared () =
  check int "14 tools pinned here" 14 (List.length expected);
  check int "14 tools bound in the module" 14 (List.length bindings)
;;

(* Three checks that lived in test_tool_descriptors_gen and have nothing to do
   with code generation. Deleting the generator's regression suite would have
   taken them with it. *)

let has_schema name schemas =
  List.exists (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) schemas
;;

(* The masc_config category enum is a literal in the TOML now, so nothing
   derives it from its owner. This is what fails when a category is added to
   one side only. *)
let test_config_category_enum_matches_its_owner () =
  check
    (list string)
    "the enum matches Env_config_snapshot.valid_config_category_strings"
    Env_config_snapshot.valid_config_category_strings
    Tool_schemas_specs_types.config_category_enum_strings
;;

let test_keeper_spawn_is_not_published () =
  check
    bool
    "keeper_spawn absent from the misc schema set"
    false
    (has_schema "keeper_spawn" Tool_schemas_misc.schemas)
;;

(* pause / resume / pause_status are Operator_only: reached through
   control_schema, never through the list a Keeper model reads. *)
let test_control_operations_stay_off_the_published_list () =
  check
    (list string)
    "the typed control projection is exhaustive"
    [ "masc_pause"; "masc_resume"; "masc_pause_status" ]
    (List.map
       (fun operation -> (Tool_schemas_misc.control_schema operation).name)
       Tool_schemas_misc.control_operations);
  List.iter
    (fun name ->
       check
         bool
         (name ^ " absent from the published misc schemas")
         false
         (has_schema name Tool_schemas_misc.schemas))
    [ "masc_pause"; "masc_resume"; "masc_pause_status" ]
;;

let () =
  run
    "operator_surface_toml_parity"
    [ ( "declaration"
      , [ test_case
            "every tool the generator owned is declared"
            `Quick
            test_every_tool_the_generator_owned_is_declared
        ] )
    ; ( "invariants_the_codegen_suite_carried"
      , [ test_case
            "the config category enum matches its owner"
            `Quick
            test_config_category_enum_matches_its_owner
        ; test_case "keeper_spawn is not published" `Quick test_keeper_spawn_is_not_published
        ; test_case
            "control operations stay off the published list"
            `Quick
            test_control_operations_stay_off_the_published_list
        ] )
    ]
;;
