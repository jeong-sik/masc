(** The publication order of [Tool_shard_types.taskboard_tools], and the
    keeper_tasks_list status enum against [Masc_domain.valid_task_status_strings].

    keeper_tasks_list builds its status enum from
    [Masc_domain.valid_task_status_strings] rather than a literal. A TOML
    literal would cut that derivation, so it stays in OCaml until it has a test
    pinning the file against its owner, the way
    [test_operator_surface_toml_parity] pins the masc_config category enum.

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone; what stays reads the published value. *)

open Alcotest


(* name, description, input_schema (keys sorted) *)
let expected =
  [ "keeper_tasks_list"
  ; "keeper_tasks_audit"
  ; "keeper_broadcast"
  ; "keeper_task_claim"
  ; "keeper_task_done"
  ; "keeper_task_cancel"
  ; "keeper_task_release"
  ; "keeper_task_create"
  ]
;;

let published = Tool_shard_types.taskboard_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.taskboard_tools")
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.taskboard_tools in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* The condition the taskboard loader named for moving keeper_tasks_list out
   of OCaml. Its status enum used to be built from
   [Masc_domain.valid_task_status_strings] at schema-construction time, so a
   new task_status constructor reached the published schema on its own. A TOML
   literal cannot do that, and the failure it replaces is silent: the tool goes
   on advertising a status list that no longer names every status, and a filter
   for the missing one is refused at the boundary with nothing to point at.

   So the derivation becomes an assertion. The declaration is read back through
   the same loader the runtime uses, not from the file text, because that is
   the value the model is handed. *)
let test_status_enum_still_names_every_task_status () =
  let published =
    List.find
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name "keeper_tasks_list")
      Tool_shard_types.taskboard_tools
  in
  let declared =
    match published.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
         (match List.assoc_opt "status" properties with
          | Some (`Assoc status_fields) ->
            (match List.assoc_opt "enum" status_fields with
             | Some (`List values) ->
               List.map
                 (function
                   | `String value -> value
                   | other -> failf "status enum holds a non-string: %s"
                                (Yojson.Safe.to_string other))
                 values
             | _ -> fail "keeper_tasks_list status carries no enum")
          | _ -> fail "keeper_tasks_list publishes no status property")
       | _ -> fail "keeper_tasks_list publishes no properties")
    | _ -> fail "keeper_tasks_list input_schema is not an object"
  in
  check
    (list string)
    "config/tools/keeper_tasks_list.toml status enum vs \
     Masc_domain.valid_task_status_strings"
    Masc_domain.valid_task_status_strings
    declared
;;

let () =
  run
    "taskboard_tool_toml_parity"
    [ ( "order"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "derivation"
      , [ test_case
            "status enum names every task_status"
            `Quick
            test_status_enum_still_names_every_task_status
        ] )
    ]
;;
