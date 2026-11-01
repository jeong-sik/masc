module Observation = Masc.Keeper_composition_observation

let json = Yojson.Safe.pretty_to_string
let sections = function
  | Observation.Absent -> []
  | Invalid detail -> ["Nested result unavailable", detail]
  | Stored reference ->
      ["Nested result retained", "Original manifest has not been read: " ^ reference.sha256]
  | Observed children ->
      List.concat_map (fun (child : Observation.child) ->
        let admission = match child.admission with
          | Not_attempted -> "not attempted"
          | Rejected reason -> "rejected\n" ^ json reason
          | Recorded {tool_use_id;frame_sha256;activation} ->
              "recorded occurrence: " ^ tool_use_id ^ "\nactivation frame: " ^ frame_sha256
              ^ "\n" ^ json (Masc.Keeper_skill_activation_ledger.activation_to_yojson activation) in
        let nodes = List.map (fun (node : Observation.node) ->
          let origin = match node.origin with
            | Arguments -> "arguments" | Submission -> "submission" | Result -> "result"
            | Child_node source -> "child node " ^ source in
          Printf.sprintf "%s → %s · %s%s%s%s" origin node.node_id
            (Option.fold ~none:"not settled" ~some:Tool_result.string_of_disposition node.disposition)
            (Option.fold ~none:"" ~some:(fun id -> "\noccurrence: " ^ id) node.tool_use_id)
            (Option.fold ~none:"" ~some:(fun value -> "\neffect: " ^ Tool_result.failure_effect_disposition_to_string value) node.effect_disposition)
            (Option.fold ~none:"" ~some:(fun value -> "\nvalidation: " ^ json value) node.validation_error)) child.nodes in
        ["Child " ^ child.alias,
          Masc.Keeper_composition_nested_run.disposition_to_string child.disposition ^ " · "
          ^ (match child.execution with Inline -> "inline" | Async -> "async")
          ^ "\n" ^ json (Skill_reference.to_yojson child.reference);
         "Declared arguments · " ^ child.alias, json child.arguments;
         "Admission · " ^ child.alias, admission]
        @ Option.to_list (Option.map (fun cause -> "Cause · " ^ child.alias,json cause) child.cause)
        @ ["Nodes · " ^ child.alias, String.concat "\n\n" nodes]
        @ List.map (fun (export : Observation.export) ->
          "Export " ^ child.alias ^ "/" ^ export.name,
          export.node_id ^ " " ^ export.pointer ^ "\n" ^
          (match export.value with Available value -> "available\n" ^ json value
           | Unavailable error -> "unavailable\n" ^ json error)) child.exports) children
