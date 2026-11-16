open Ports
let assertions=ref 0
let expect label condition=incr assertions;if not condition then failwith label
let observe f=
 trace:=[];ledger_calls:=0;
 let result=f () in result,List.rev !trace,!ledger_calls
let without_ledger=function
 | `Assoc fields->`Assoc(List.remove_assoc "keeper_reaction_ledger" fields)
 | json->json
let tools_without_ledger=function
 | `Assoc fields->`Assoc(List.map(fun(key,value)->key,
     if key="runtime_resolution" then without_ledger value else value) fields)
 | json->json
let result_json=function
 | Dashboard_snapshot.Tools_ready json->"ready",json
 | Tools_pending json->"pending",json
 | Tools_error json->"error",json
let config={Workspace.base_path="/fixture/base";workspace_path="/fixture/workspace"}
let ()=
 for index=0 to 4 do
  scenario:=index;state_present:=index<>3;
  let full_b,trace_b,calls_b=observe(fun()->Baseline.runtime_resolution_json config) in
  let full_c,trace_c,calls_c=observe(fun()->Candidate.runtime_resolution_json config) in
  expect "full runtime exact output and effect-order parity" (full_b=full_c && trace_b=trace_c);
  expect "full runtime still computes ledger once" (calls_b=1 && calls_c=1);
  let fleet_b,trace_b,_=observe(fun()->Fleet_baseline.keeper_fleet_runtime_resolution_fields ()) in
  let fleet_c,trace_c,calls=observe(fun()->Fleet_candidate.keeper_fleet_runtime_resolution_tools_fields ()) in
  expect "Tools fleet is full fleet minus only ledger" (List.remove_assoc "keeper_reaction_ledger" fleet_b=fleet_c);
  expect "Tools preserves full fleet effect order except ledger" (List.filter((<>)"ledger") trace_b=trace_c && calls=0);
  expect "phase precedes metadata and full boot-path projection" (not !state_present ||
    match List.filter(fun label->List.mem label ["phase";"metas";"meta_scan/full";"boot_path"]) trace_c with
    | "phase"::"metas"::remaining->List.sort String.compare remaining=["boot_path";"meta_scan/full"]
    | _->false);
  if !state_present then begin
   let paused=Yojson.Safe.Util.(`Assoc fleet_c |>member "paused_keepers_health" |>member "details") in
   expect "Tools keeps nonempty full paused details" (paused=paused_details);
   expect "Tools retains boot-path override instead of light scan's invalid-profile member"
     (List.assoc "keeper_fleet_safety" fleet_c=marker(if index=4 then "unread-census" else "valid"))
  end;
  List.iter(fun read_policy->List.iter(fun keeper->List.iter(fun mode->List.iter(fun timing->
   Dashboard_cache.mode:=mode;
   let (state_b,json_b),trace_b,calls_b=observe(fun()->
     Baseline.dashboard_tools_http_result ~read_policy ?keeper ?timing config |>result_json) in
   let (state_c,json_c),trace_c,calls_c=observe(fun()->
     Candidate.dashboard_tools_http_result ~read_policy ?keeper ?timing config |>result_json) in
   expect "Tools response differs only by intentional runtime ledger field" (state_b=state_c && tools_without_ledger json_b=json_c);
   expect "Tools never invokes ledger, including selected/current/reuse/warming/error" (calls_c=0);
   expect "Tools effect order unchanged outside ledger" (List.filter((<>)"ledger") trace_b=trace_c);
   expect "baseline computed Tools reads ledger exactly once"
     (calls_b=(if read_policy=Dashboard_projection_read.Current || mode=Dashboard_cache.Computed then 1 else 0)))
      [None;Some ()]) [Dashboard_cache.Computed;Seeded;Timeout]) [None;Some "held";Some "missing"])
      [Dashboard_projection_read.Current;Reuse]
 done;
 scenario:=0;state_present:=true;Dashboard_cache.mode:=Dashboard_cache.Computed;
 refuse_ledger:=true;
 let refused f=try ignore(f ());false with Forbidden_ledger_access->true in
 expect "failing ledger port is reachable on baseline Tools" (refused(fun()->Baseline.dashboard_tools_http_result ~read_policy:Current config));
 expect "failing ledger port remains authoritative on full runtime" (refused(fun()->Candidate.runtime_resolution_json config));
 List.iter(fun policy->
   let _,_,calls=observe(fun()->Candidate.dashboard_tools_http_result ~read_policy:policy ~keeper:"held" config) in
   expect "Tools succeeds without touching failing ledger port" (calls=0)) [Dashboard_projection_read.Current;Reuse];
 refuse_ledger:=false;
 let _,_,calls=observe(fun()->full_health_ledger_section ~execution_snapshot:() ()) in
 expect "unchanged actual full-health ledger section calls leaf once" (calls=1);
 let encode f=f () |>result_json |>snd |>Yojson.Safe.to_string in
 let baseline ()=encode(fun()->Baseline.dashboard_tools_http_result ~read_policy:Current config)
 and candidate ()=encode(fun()->Candidate.dashboard_tools_http_result ~read_policy:Current config) in
 let baseline_bytes=String.length(baseline ()) and candidate_bytes=String.length(candidate ()) in
 let measure label f=
  Gc.full_major ();ledger_calls:=0;
  let allocated=Gc.allocated_bytes () and cpu=Sys.time () in
  for _=1 to 100 do ignore(Sys.opaque_identity(f ())) done;
  `Assoc["label",`String label;"iterations",`Int 100;"ledger_leaf_calls",`Int !ledger_calls;
    "allocated_bytes",`Float(Gc.allocated_bytes ()-.allocated);"cpu_s",`Float(Sys.time ()-.cpu)] in
 let measured=[measure "baseline_tools_fixture" baseline;measure "candidate_tools_fixture" candidate] in
 Printf.printf "%s\n" (Yojson.Safe.to_string(`Assoc[
   "native_assertions",`Int !assertions;"baseline_payload_bytes",`Int baseline_bytes;
   "candidate_payload_bytes",`Int candidate_bytes;"measurements",`List measured]))
