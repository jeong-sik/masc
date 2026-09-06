(** Byte-identity pins for the run tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_schemas_run.schemas] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    Nothing here derives a value from an owner module, so the whole list
    moves in one step.

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
    [ {|masc_run_init|}, {|Create an execution memory directory to track the run plan.

The directory is .masc/runs/{task_id}/. Call when starting work on a claimed task to enable structured progress tracking. After init, use masc_run_plan to set approach and masc_run_get to review.|}, {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Agent working on the task","type":"string"},"task_id":{"description":"Task ID to track","type":"string"}},"required":["task_id","agent_name"],"type":"object"}|}
    ; {|masc_run_plan|}, {|Set or update the execution plan (markdown) for a task run; each update creates a new revision. \nCall after masc_run_init to document your approach before starting implementation. \nOther agents can view plans via masc_run_get for workspace and handoff context.|}, {|{"additionalProperties":false,"properties":{"plan":{"description":"The plan (markdown supported)","type":"string"},"task_id":{"description":"Task ID","type":"string"}},"required":["task_id","plan"],"type":"object"}|}
    ; {|masc_run_get|}, {|Retrieve the run record and execution plan for a task. \nIf the task has no run record yet, create an empty run scaffold and return it so resume flow can continue. \nUse when resuming work on a task, reviewing progress, or preparing a handoff. \nPair with masc_run_plan to set the plan.|}, {|{"additionalProperties":false,"properties":{"task_id":{"description":"Task ID to retrieve","type":"string"}},"required":["task_id"],"type":"object"}|}
    ; {|masc_run_list|}, {|List all task runs with their status (active/completed) and plan presence.

\nUse when starting a session to find abandoned work or review completed runs. \nAfter finding a run, call masc_run_get for full details or masc_run_init to start a new one.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ]
;;

let published = Tool_schemas_run.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_run.schemas")
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
    "Tool_schemas_run.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "run_tool_toml_parity"
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
