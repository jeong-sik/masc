(** Config Module Coverage Tests

    Tests for the schema registry helpers that remain after mode removal.
*)

open Alcotest

module Config = Masc.Config
module Auth = Auth
module Tool_catalog = Tool_catalog
module Tool_help_registry = Tool_help_registry
module Tool_shard = Masc.Tool_shard
module Types = Masc_domain

let test_raw_all_tool_schemas_non_empty () =
  check bool "raw schemas exist" true (List.length Config.raw_all_tool_schemas > 0)

let test_raw_all_tool_schema_names_are_unique () =
  let names =
    Config.raw_all_tool_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  let counts = Hashtbl.create (List.length names) in
  List.iter
    (fun name ->
       Hashtbl.replace counts name
         (Option.value ~default:0 (Hashtbl.find_opt counts name) + 1))
    names;
  let duplicates =
    Hashtbl.to_seq counts
    |> Seq.filter_map (fun (name, count) ->
           if count > 1 then Some (Printf.sprintf "%s×%d" name count) else None)
    |> List.of_seq
    |> List.sort String.compare
  in
  check (list string) "raw schema names are unique" [] duplicates

let test_all_tool_schemas_non_empty () =
  check bool "public schemas exist" true (List.length Config.all_tool_schemas > 0)

let test_all_tool_names_omits_hidden_pause () =
  check bool "masc_pause hidden from public schemas" false
    (List.mem "masc_pause" (Config.all_tool_names ()))

let test_shard_base_tools_registered_for_help () =
  List.iter
    (fun (tool : Masc_domain.tool_schema) ->
      let registered =
        Config.raw_all_tool_schemas
        |> List.exists (fun (schema : Masc_domain.tool_schema) ->
               String.equal schema.name tool.name)
      in
      check bool (tool.name ^ " in raw schemas") true registered;
      match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool.name with
      | Some entry ->
          check string (tool.name ^ " help name") tool.name entry.name
      | None -> failf "%s missing from tool help registry" tool.name)
    Tool_shard.base_tools


let test_visible_tool_schemas_subset_of_all () =
  let visible = Config.visible_tool_schemas () in
  check bool "visible <= all" true
    (List.length visible <= List.length Config.all_tool_schemas)

let test_is_tool_allowed_pause () =
  (* masc_pause is an admin-surface tool with a descriptor. *)
  check bool "pause allowed on admin/catalog surface" true
    (Config.is_tool_allowed "masc_pause");
  check bool "pause included with include_hidden" true
    (Tool_catalog.is_visible ~include_hidden:true "masc_pause")

(* A malformed retention value used to mean opposite things: two stores kept
   files forever and one began pruning at its own default, while each of the
   two cited the third as its model. One operator typo therefore deleted from
   one store and stopped deleting from another (#27110). *)
let test_malformed_retention_lands_on_the_declared_default () =
  let module E = Env_config_core in
  let name = "MASC_TEST_RETENTION_DAYS_PROBE" in
  let with_env value f =
    let prior = Sys.getenv_opt name in
    Unix.putenv name value;
    Fun.protect
      ~finally:(fun () ->
        match prior with Some v -> Unix.putenv name v | None -> Unix.putenv name "")
      f
  in
  let check_case label value ~default expected =
    with_env value (fun () ->
      Alcotest.(check bool) label true
        (E.get_retention_days ~default name = expected))
  in
  (* Garbage takes the store's own default, whichever it is. *)
  check_case "malformed keeps an opt-in store opt-in" "3O"
    ~default:E.Retain_forever E.Retain_forever;
  check_case "malformed keeps an opt-out store pruning" "3O"
    ~default:(E.Prune_after_days 30) (E.Prune_after_days 30);
  (* Zero says the same thing in every store. *)
  check_case "explicit zero keeps everything" "0"
    ~default:(E.Prune_after_days 30) E.Retain_forever;
  check_case "negative keeps everything" "-1"
    ~default:(E.Prune_after_days 30) E.Retain_forever;
  check_case "a positive value is the window" "7"
    ~default:E.Retain_forever (E.Prune_after_days 7);
  check_case "empty is unset" "  "
    ~default:(E.Prune_after_days 30) (E.Prune_after_days 30)
;;

let () =
  run "Config Coverage"
    [
      ( "schema_registry",
        [
          test_case "raw schemas non-empty" `Quick
            test_raw_all_tool_schemas_non_empty;
          test_case "raw schema names are unique" `Quick
            test_raw_all_tool_schema_names_are_unique;
          test_case "all schemas non-empty" `Quick
            test_all_tool_schemas_non_empty;
          test_case "all_tool_names omits hidden pause" `Quick
            test_all_tool_names_omits_hidden_pause;
          test_case "shard base tools registered for help" `Quick
            test_shard_base_tools_registered_for_help;
          test_case "visible is subset of all" `Quick
            test_visible_tool_schemas_subset_of_all;
          test_case "pause public catalog allowed" `Quick test_is_tool_allowed_pause;
        ] );
      ( "retention",
        [
          test_case "malformed lands on the declared default" `Quick
            test_malformed_retention_lands_on_the_declared_default;
        ] );
    ]
