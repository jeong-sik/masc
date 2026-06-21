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

let route_evidence_has_semantic_fields = function
  | Some (`Assoc fields) ->
      List.exists
        (fun (key, _value) ->
          String.equal key "descriptor_id"
          || String.equal key "runtime_handler"
          || String.equal key "receipt_labels"
          || String.equal key "eval_tags")
        fields
  | _ -> false

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
