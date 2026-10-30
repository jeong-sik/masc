open Alcotest

(** [Eval_tool_selector] is an eval/shadow/replay matcher over recorded
    tool-call evidence. It must not become live keeper/runtime routing policy. *)

(* [to_yojson] writes a ["type"]-tagged object. Every other JSON shape decodes
   to a typed error, so a malformed selector cannot fold into a name match that
   silently weakens the expectation it was written for. *)
let decodes raw = Eval_tool_selector.of_yojson (Yojson.Safe.from_string raw)

let test_accepts_the_shapes_to_yojson_writes () =
  List.iter
    (fun (selector, expected_label) ->
      match decodes (Yojson.Safe.to_string (Eval_tool_selector.to_yojson selector)) with
      | Ok decoded -> check string "round trip" expected_label (Eval_tool_selector.label decoded)
      | Error message -> failf "%s should decode: %s" expected_label message)
    [ Eval_tool_selector.Tool_name "tool_execute", "tool_name:tool_execute"
    ; Eval_tool_selector.Descriptor_id "masc.agent.card", "descriptor_id:masc.agent.card"
    ; Eval_tool_selector.Runtime_handler "Tool_masc_agent_dispatch",
      "runtime_handler:Tool_masc_agent_dispatch"
    ; Eval_tool_selector.Eval_tag "agent_profile_lookup", "eval_tag:agent_profile_lookup"
    ; Eval_tool_selector.Receipt_label ("family", "lookup"), "receipt_label:family=lookup"
    ]
;;

let test_rejects_every_other_shape () =
  List.iter
    (fun (name, raw) ->
      match decodes raw with
      | Error _ -> ()
      | Ok decoded ->
        failf "%s must not decode, got %s" name (Eval_tool_selector.label decoded))
    [ "bare string", {|"tool_execute"|}
    ; "kind key", {|{"kind":"tool_name","value":"tool_execute"}|}
    ; "tool alias", {|{"type":"tool","value":"tool_execute"}|}
    ; "name alias", {|{"type":"name","value":"tool_execute"}|}
    ; "descriptor alias", {|{"type":"descriptor","value":"masc.agent.card"}|}
    ; "handler alias", {|{"type":"handler","value":"Tool_x"}|}
    ; "tag alias", {|{"type":"tag","value":"lookup"}|}
    ; "bare tool_name key", {|{"tool_name":"tool_execute"}|}
    ; "bare descriptor_id key", {|{"descriptor_id":"masc.agent.card"}|}
    ]
;;

let () =
  run
    "eval-tool-selector-boundary"
    [ ( "decoder shape"
      , [ test_case
            "accepts the shapes to_yojson writes"
            `Quick
            test_accepts_the_shapes_to_yojson_writes
        ; test_case
            "rejects every other shape"
            `Quick
            test_rejects_every_other_shape
        ] )
    ]
;;
