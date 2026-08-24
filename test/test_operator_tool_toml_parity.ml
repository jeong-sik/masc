(** Byte-identity pins for the operator tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Operator_tool.schemas] before any file moved, so this
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
    [ {|masc_operator_snapshot|}, {|Read unified operator state for the default workspace, keepers, recent messages, and pending confirmations before acting.|}, {|{"properties":{"actor":{"type":"string"},"include_keepers":{"type":"boolean"},"include_messages":{"type":"boolean"},"view":{"enum":["summary","keepers","messages","full"],"type":"string"}},"type":"object"}|}
    ; {|masc_operator_digest|}, {|Read a high-signal operator digest with intervention recommendations for the default workspace when raw snapshot data is too low-level.|}, {|{"properties":{"actor":{"type":"string"},"include_workers":{"type":"boolean"},"target_id":{"type":"string"},"target_type":{"enum":["workspace"],"type":"string"}},"type":"object"}|}
    ; {|masc_operator_action|}, {|Run a structured operator action against the namespace or a keeper. Use this when you need guided control with preview-confirm safety for disruptive actions.|}, {|{"properties":{"action_type":{"enum":["broadcast","namespace_pause","namespace_resume","task_inject","keeper_message","keeper_probe","keeper_recover"],"type":"string"},"actor":{"type":"string"},"payload":{"type":"object"},"target_id":{"type":"string"},"target_type":{"enum":["workspace","keeper","goal"],"type":"string"}},"required":["action_type","payload"],"type":"object"}|}
    ; {|masc_operator_board_attention_quarantine_requeue|}, {|Acknowledge and requeue exactly one Board-attention quarantine. The observed keeper, partition, candidate, and opaque quarantine id must all match; this tool never auto-retries.|}, {|{"additionalProperties":false,"properties":{"candidate_id":{"minLength":1,"type":"string"},"decision":{"enum":["acknowledge_and_requeue"],"type":"string"},"expected_quarantine_id":{"minLength":1,"type":"string"},"keeper_name":{"minLength":1,"type":"string"},"partition_id":{"minLength":1,"type":"string"},"schema":{"enum":["keeper.board_attention.quarantine.recovery.command.v1"],"type":"string"}},"required":["schema","keeper_name","partition_id","candidate_id","expected_quarantine_id","decision"],"type":"object"}|}
    ; {|masc_operator_task_recovery_resolve|}, {|Recover exactly one claimed or in-progress Task to todo. The observed task_id, persisted assignee, and backlog version must all match; this tool performs no liveness or elapsed-time inference.|}, {|{"additionalProperties":false,"properties":{"expected_assignee":{"minLength":1,"type":"string"},"expected_version":{"minimum":0,"type":"integer"},"reason":{"minLength":1,"type":"string"},"schema":{"enum":["workspace.task.operator_recovery.command.v1"],"type":"string"},"task_id":{"minLength":1,"type":"string"}},"required":["schema","task_id","expected_assignee","expected_version","reason"],"type":"object"}|}
    ; {|masc_operator_confirm|}, {|Confirm and execute a previously previewed operator action. Use this only after masc_operator_action returns confirm_required=true.|}, {|{"properties":{"actor":{"type":"string"},"confirm_token":{"type":"string"},"decision":{"enum":["confirm","deny"],"type":"string"}},"required":["confirm_token"],"type":"object"}|}
    ; {|masc_operator_judgment_write|}, {|Internal operator-judge write path. Use this to store a durable operator judgment for namespace supervision. Hidden from the default catalog and intended for keeper/automation experiments.|}, {|{"properties":{"confidence":{"description":"How sure the judge is, 0.0-1.0. Shown to the operator; no code compares it.","maximum":1.0,"minimum":0.0,"type":"number"},"disagreement_with_truth":{"type":"boolean"},"evidence_refs":{"items":{"type":"string"},"type":"array"},"fallback_used":{"type":"boolean"},"fresh_ttl_sec":{"type":"integer"},"keeper_name":{"type":"string"},"model_name":{"type":"string"},"recommended_action":{"type":"object"},"runtime_name":{"type":"string"},"summary":{"type":"string"},"surface":{"enum":["command.namespace","intervene"],"type":"string"},"target_id":{"type":"string"},"target_type":{"enum":["workspace"],"type":"string"}},"required":["surface","target_type","summary","confidence"],"type":"object"}|}
    ]
;;

let published = Operator_tool.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Operator_tool.schemas")
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
    "Operator_tool.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "operator_tool_toml_parity"
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
