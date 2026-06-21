module Hashtbl = Stdlib.Hashtbl
module List = Stdlib.List
module String = Stdlib.String

open Tool_call_quality_benchmark_types

let semantic_selectors (benchmark_case : benchmark_case) =
  let arg_selectors =
    benchmark_case.arg_checks |> List.map (fun check -> check.selector)
  in
  benchmark_case.forbidden_selectors @ benchmark_case.required_selectors
  @ arg_selectors
  |> List.filter Eval_tool_selector.requires_route_evidence

(* A semantic selector matches route_evidence only when the relevant field
   carries a usable value: a non-empty descriptor/handler string, a non-empty
   eval-tag list, or a receipt-label assoc with at least one non-empty string
   value. Empty values ([{"descriptor_id": ""}], [{"eval_tags": []}], ...)
   cannot match any parsed selector, because Eval_tool_selector.of_yojson
   rejects empty selector values, so they are not route evidence. This mirrors
   {!Eval_tool_selector.matches}, which reads the same fields via
   Json_util.assoc_string_opt / json_string_list_member / the receipt_labels
   assoc and likewise yields no match for empty values. Checking only key
   presence here would let vacuous evidence pass the gate. *)
let route_evidence_has_semantic_fields = function
  | Some json ->
      let has_string field =
        Option.is_some (Json_util.assoc_string_opt field json)
      in
      let has_eval_tags =
        match Json_util.json_string_list_member "eval_tags" json with
        | [] -> false
        | _ :: _ -> true
      in
      let has_receipt_label =
        match Json_util.assoc_member_opt "receipt_labels" json with
        | Some (`Assoc receipt_fields) ->
            List.exists
              (fun (_key, value) ->
                match value with
                | `String text -> not (String.equal (String.trim text) "")
                | _ -> false)
              receipt_fields
        | _ -> false
      in
      has_string "descriptor_id" || has_string "runtime_handler" || has_eval_tags
      || has_receipt_label
  | None -> false

let cases_by_id cases =
  cases
  |> List.to_seq
  |> Stdlib.Seq.map (fun benchmark_case -> (benchmark_case.id, benchmark_case))
  |> Hashtbl.of_seq

let route_evidence_issues ~cases ~runs =
  let case_table = cases_by_id cases in
  runs
  |> List.concat_map (fun (run : evidence_run) ->
         match run.status, Hashtbl.find_opt case_table run.case_id with
         | Run_ok, Some benchmark_case
           when List.mem run.keeper_profile benchmark_case.keeper_profiles ->
             let selectors = semantic_selectors benchmark_case in
             if List.equal (=) selectors [] then []
             else
               let selector_labels = List.map Eval_tool_selector.label selectors in
               run.tool_calls
               |> List.mapi (fun tool_call_index (call : tool_call) ->
                      if route_evidence_has_semantic_fields call.route_evidence then
                        None
                      else
                        Some
                          {
                            kind = Missing_route_evidence;
                            case_id = run.case_id;
                            provider = run.provider;
                            model = run.model;
                            keeper_profile = run.keeper_profile;
                            run_id = run.run_id;
                            tool_call_index;
                            tool_name = call.tool_name;
                            selector_labels;
                          })
               |> List.filter_map (fun issue -> issue)
         | _ -> [])
