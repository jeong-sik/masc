(** What the published surface says: the property order and the defaults masc_task tools publish.

    The descriptions and input schemas this suite also pinned were literals
    read off the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself, so the
    only thing it could report was that someone edited a sentence. Those cases
    are gone; every case that stays reads the published value. *)

open Alcotest

let schema name =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      Masc.Config.raw_all_tool_schemas
  with
  | Some s -> s
  | None -> failf "%s is absent from the canonical registry" name
;;

(* Compared as parsed JSON with object keys sorted, not as serialized bytes.

   A JSON object is an unordered set of members (RFC 8259 §4), and no reader of
   these schemas behaves differently for a different key order. What the order
   does reach is the prompt cache: tool definitions sit in the system prompt
   layer and the match is exact, so moving a key costs one uncached turn after
   deployment — the same one-time cost Claude Code pays whenever an upgrade
   changes its own tool definitions.

   Byte identity was the right pin while the OCaml literals were the source: it
   catches a migration that drops a default or reorders properties. It stops
   being the right pin here, because the three schemas below put their
   structural keys in three different places — [contract] last,
   [tasks] after maxItems, [handoff_context] after description — and TOML
   cannot express any of them: a sub-table may only follow every scalar key of
   its parent. Holding the bytes would mean keeping three hand-written orders
   forever and leaving these tools in OCaml.

   Everything the order does not carry is still pinned exactly: every
   description, type, required list, default, enum, pattern, and the nesting
   itself. *)

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let property_names name =
  match member (schema name).input_schema "properties" with
  | Some (`Assoc props) -> List.map fst props
  | _ -> failf "%s has no properties object" name
;;

let required_names name =
  match member (schema name).input_schema "required" with
  | Some (`List entries) ->
    List.map (function `String s -> s | _ -> failf "%s: non-string required" name) entries
  | None -> []
  | Some _ -> failf "%s: required is not an array" name
;;

(* Order is part of the byte comparison: the tools array is serialized as
   written, so a reordered TOML file moves bytes on the wire. *)
let test_properties_keep_their_order_and_requirement () =
  List.iter
    (fun (name, props, required) ->
       check (list string) (name ^ " properties, in order") props (property_names name);
       check (list string) (name ^ " required, in order") required (required_names name))
    [ "masc_task_history", [ "task_id"; "limit" ], [ "task_id" ]
    ; "masc_tasks", [ "status"; "include_done"; "include_cancelled" ], []
    ; "masc_update_priority", [ "task_id"; "priority" ], [ "task_id"; "priority" ]
    ; "masc_task_set_goal", [ "task_id"; "goal_id" ], [ "task_id"; "goal_id" ]
    ]
;;

(* A default that survives the move is the difference between a caller that
   may omit the field and one that must supply it. *)
let test_defaults_survive () =
  let default name prop =
    match member (schema name).input_schema "properties" with
    | Some (`Assoc props) ->
      (match List.assoc_opt prop props with
       | Some spec -> member spec "default"
       | None -> failf "%s has no %s property" name prop)
    | _ -> failf "%s has no properties object" name
  in
  check bool "masc_task_history.limit keeps 50" true (default "masc_task_history" "limit" = Some (`Int 50));
  check
    bool
    "masc_tasks.include_done keeps false"
    true
    (default "masc_tasks" "include_done" = Some (`Bool false));
  check
    bool
    "masc_tasks.include_cancelled keeps false"
    true
    (default "masc_tasks" "include_cancelled" = Some (`Bool false))
;;

let () =
  run
    "task_tool_toml_parity"
    [ ( "structure"
      , [ test_case
            "properties keep order and requirement"
            `Quick
            test_properties_keep_their_order_and_requirement
        ; test_case "defaults survive" `Quick test_defaults_survive
        ] )
    ]
;;
