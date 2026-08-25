(** Byte-identity pins for the workspace core toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_schemas_workspace_core.schemas] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    Nothing here derives a value from an owner module.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|masc_status|}, {|Get current project status: active agents, task queue, recent broadcasts, and cluster info. Use when you need a snapshot of who is online and what tasks are available. Call after masc_start to orient yourself. Pair with masc_tasks for detailed backlog.|}, {|{"additionalProperties":false,"properties":{"if_revision":{"description":"Optional producer revision from the previous snapshot; matching revisions return unchanged.","type":"string"}},"type":"object"}|}
    ; {|masc_check|}, {|Assert task preconditions on your agent state (task claimed, current task set, etc). Call when you want to confirm prerequisites before starting work; returns pass/fail with fix hints.|}, {|{"additionalProperties":false,"properties":{"assertions":{"description":"List of task-state assertions to check. Each returns true/false with a fix hint if false.","items":{"enum":["task_claimed","current_task_set"],"type":"string"},"type":"array"}},"required":["assertions"],"type":"object"}|}
    ; {|masc_heartbeat|}, {|Publish the caller's heartbeat observation. Heartbeats are telemetry only and do not grant another component authority to stop, evict, or release the caller's work.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ]
;;

let published = Tool_schemas_workspace_core.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_workspace_core.schemas")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_workspace_core.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "workspace_core_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
