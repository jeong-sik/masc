let checks=ref 0
let expect label yes=incr checks;if not yes then failwith label
let message role origin content : Agent_core.Types.message=
 {role;origin;content;name=None;tool_call_id=None;metadata=[]}
let plain role origin text=message role origin [Agent_core.Types.Text text]
let outcome f=try Ok(f ()) with Yojson.Json_error error->Error error
let origins : Agent_core.Types.message_origin list=
 [System_context;Conversation;Recovery_instruction;Tool_result_followup;
  Agent_instruction;Historical_system_context]
let roles : Agent_core.Types.role list=[System;User;Assistant;Tool]
let valid_pool=List.concat_map(fun role->List.map(fun origin->plain role origin "fixture")origins)roles
let bad=message Assistant Conversation [ToolUse{id="fixture";name="fixture";input=`Float nan}]
let histories=
 let random=Random.State.make [|20261117|] in
 let fixed=[[];[bad];[List.hd valid_pool;bad];List.rev valid_pool;valid_pool;
  [plain Tool Conversation "orphan";plain Tool Conversation "attached";
   plain User Conversation "user";plain System Historical_system_context "historical"]] in
 fixed@List.init 120(fun _->List.init(Random.State.int random 80)(fun _->
   List.nth valid_pool (Random.State.int random (List.length valid_pool))))
let ()=
 List.iter(fun history->
  let _,expected_count=Before.annotate history in
  let old=Before.atom_opening_digest history in
  let count,digest_at=After.atom_opening_index history in
  let lookup_only=After.atom_opening_digest history in
  expect "actual annotate count" (count=expected_count);
  for atom=(-2) to count+2 do
   let expected=outcome(fun()->old atom) in
   expect "same exact bytes/error at every index" (outcome(fun()->digest_at atom)=expected);
   expect "lookup-only API unchanged" (outcome(fun()->lookup_only atom)=expected)
  done)histories
let ()=
 let count,digest_at=After.atom_opening_index [bad] in
 expect "invalid opener is not encoded at construction" (count=1);
 expect "invalid opener outside bounds is not encoded" (digest_at 1=None);
 expect "invalid opener still fails at lookup" (match outcome(fun()->digest_at 0) with Error _->true|Ok _->false)
let measure make history iterations=
 Gc.full_major ();
 let allocated=Gc.allocated_bytes () and cpu=Sys.time () and wall=Unix.gettimeofday () in
 let checksum=ref 0 in
 for _=1 to iterations do checksum:= !checksum lxor make history done;
 `Assoc["allocated_bytes",`Float(Gc.allocated_bytes ()-.allocated);"cpu_seconds",`Float(Sys.time ()-.cpu);
  "wall_seconds",`Float(Unix.gettimeofday ()-.wall);"checksum",`Int !checksum]
let benchmark ()=
 let combined_before history=let _,count=Before.annotate history in
  let lookup=Before.atom_opening_digest history in ignore(Sys.opaque_identity lookup);count in
 let combined_after history=let count,lookup=After.atom_opening_index history in
  ignore(Sys.opaque_identity lookup);count in
 let lookup_before history=let lookup=Before.atom_opening_digest history in
  ignore(Sys.opaque_identity lookup);0 in
 let lookup_after history=let lookup=After.atom_opening_digest history in
  ignore(Sys.opaque_identity lookup);0 in
 List.concat_map(fun(size,iterations)->
  let history=List.init size(fun index->List.nth valid_pool(index mod List.length valid_pool)) in
  List.map(fun(label,before,after)->
   let rounds=List.init 6(fun round->
    let a,b=if round mod 2=0 then let a=measure before history iterations in a,measure after history iterations
     else let b=measure after history iterations in measure before history iterations,b in
    `Assoc["order",`String(if round mod 2=0 then "AB" else "BA");"baseline",a;"candidate",b]) in
   `Assoc["mode",`String label;"messages",`Int size;"iterations_per_round",`Int iterations;"rounds",`List rounds])
   ["count_and_lookup",combined_before,combined_after;"lookup_only",lookup_before,lookup_after])
 [0,20000000;1,10000000;100,100000;10000,250]
let ()=Printf.printf "%s\n" (Yojson.Safe.to_string(`Assoc[
 "oracle_histories",`Int(List.length histories);"oracle_checks",`Int !checks;
 "existing_baseline_tests",`Int !before_tests;"existing_candidate_tests",`Int !after_tests;
 "benchmarks",`List(benchmark())]))
