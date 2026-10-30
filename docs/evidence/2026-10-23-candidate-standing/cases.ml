module Artifact_standing = Artifact_boundary.Runtime_candidate_standing
module Artifact_pressure = Artifact_boundary.Runtime_candidate_backpressure
module Artifact_quota = Artifact_boundary.Runtime_quota_window
let tests = ref 0
let check label condition = if not condition then failwith label
let case label f = f (); incr tests; Printf.printf "PASS %s\n%!" label
let candidate () = Artifact_pressure.create_candidate ~binding:Artifact_pressure.Official_client_binding
let scope label = Artifact_quota.scope_of_credential ~provider_id:label None
let keeper_a = Artifact_pressure.keeper_recorder ~keeper_name:"artifact-keeper-a"
let keeper_b = Artifact_pressure.keeper_recorder ~keeper_name:"artifact-keeper-b"
let rate_policy = Artifact_standing.Rate_rest_only {rest_sec=(fun ~retry_after -> Option.value retry_after ~default:7.)}
type row = {id:string;candidate:Artifact_pressure.candidate option;scope:Artifact_quota.scope option}
let row id = {id;candidate=Some (candidate ());scope=Some (scope id)}
let pressure row = Option.get row.candidate
let quota row = Option.get row.scope
let order ~now ~policy rows = Artifact_standing.order ~now ~policy
  ~quota_scope_of:(fun row -> row.scope) ~candidate_backpressure_of:(fun row -> row.candidate)
  rows |> List.map (fun row -> row.id)
let note row observation = Artifact_standing.observe ~candidate:row.candidate ~quota_scope:row.scope observation
let failed row = Artifact_pressure.note_failed_attempt ~candidate:(pressure row)
  ~failure:Artifact_pressure.Provider_timeout ~recorded_by:keeper_a
let noted row = match Artifact_pressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate:(pressure row) with
| Some {rate_limit=Some (Unknown_scope_rate_limit {noted_at;_});_} -> noted_at
| Some {rate_limit=None;_} | None -> failwith "rate observation absent"
let () =
Artifact_quota.reset_for_testing ();
case "keeper fresh / other / EveryMark preserve three classes and rows" (fun () ->
 let failed_row=row "failed" and clean=row "clean" and rate=row "rate" and hard=row "hard" in
 failed failed_row;note rate (Rate_limited {retry_after=Some 100.});note hard (Hard_quota {resets_at=None});
 let unknown={id="unknown";candidate=None;scope=None} in
 let rows=[rate;failed_row;unknown;clean;hard] in
 let now=Unix.gettimeofday () in
 check "fresh recorder own failure place" (order ~now ~policy:(Keeper_walk (Fresh_walk_by keeper_a)) rows=["failed";"unknown";"clean";"rate";"hard"]);
 List.iter (fun policy -> check "every other failure demotes" (order ~now ~policy rows=["unknown";"clean";"failed";"rate";"hard"]))
 [Keeper_walk (Fresh_walk_by keeper_b);Keeper_walk Every_mark_demotes]);
case "RateRestOnly ignores Fleet failed attempts" (fun () ->
 let first=row "first" and second=row "second" in failed first;
 check "failed attempt does not change rate-only order" (order ~now:(Unix.gettimeofday ()) ~policy:rate_policy [first;second]=["first";"second"]));
case "provider hint beyond fallback cap is preserved" (fun () ->
 let first=row "hint" and second=row "hint-sibling" in note first (Rate_limited {retry_after=Some 100.});let now=noted first in
 check "long stated rest" (order ~now:(now+.31.) ~policy:rate_policy [first;second]=["hint-sibling";"hint"]);
 check "provider release" (order ~now:(now+.101.) ~policy:rate_policy [first;second]=["hint";"hint-sibling"]));
case "unhinted rate uses explicit caller callback and leaves no TTL in state" (fun () ->
 let first=row "floor" and second=row "floor-sibling" in note first (Rate_limited {retry_after=None});let now=noted first in
 let floor=7. in
 check "inside floor" (order ~now:(now+.floor/.2.) ~policy:rate_policy [first;second]=["floor-sibling";"floor"]);
 check "after floor" (order ~now:(now+.floor+.1.) ~policy:rate_policy [first;second]=["floor";"floor-sibling"]);
 check "Keeper policy still sees unhinted evidence" (order ~now:(now+.floor+.1.) ~policy:(Keeper_walk Every_mark_demotes) [first;second]=["floor-sibling";"floor"]));
case "all resting candidates and unresolved row are preserved" (fun () ->
 let first=row "all-a" and second=row "all-b" in note first (Hard_quota {resets_at=None});note second (Hard_quota {resets_at=None});
 check "all declared rows survive" (order ~now:(Unix.gettimeofday ()) ~policy:rate_policy [first;second]=["all-a";"all-b"]));
case "typed rate never contaminates same-scope sibling quota" (fun () ->
 let first=row "rate-only" in let sibling={ (row "same-scope-sibling") with scope=first.scope } in
 note first (Rate_limited {retry_after=Some 90.});
 check "candidate records typed rate observation" (Option.is_some (Artifact_pressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate:(pressure first)));
 check "shared quota unchanged" (not (Artifact_quota.is_exhausted ~scope:(quota sibling) ~now:(Unix.gettimeofday ())));
 check "sibling candidate unchanged" (Option.is_none (Artifact_pressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate:(pressure sibling))));
case "typed HardQuota records account and preserves provider reset after answer" (fun () ->
 let target=row "typed-quota" in let now=Unix.gettimeofday () in
 Artifact_standing.observe_http_error ~now ~candidate:(pressure target) ~quota_scope:(quota target)
  (Artifact_boundary.Llm_provider.Http_client.ProviderFailure {kind=Hard_quota {retry_after=Some 90.};message="typed account refusal"});
 check "stated reset recorded" (Artifact_quota.active_until ~scope:(quota target) ~now=Some (now+.90.));
 note target Answered;
 check "success does not erase provider reset" (Artifact_quota.active_until ~scope:(quota target) ~now=Some (now+.90.)));
case "answered clears actual candidate / undated quota before semantic rejection" (fun () ->
 let target=row "answered" in failed target;note target (Rate_limited {retry_after=None});note target (Hard_quota {resets_at=None});
 note target Answered;
 let semantic_result = Error "synthetic domain validation rejects received answer" in
 check "semantic validation still rejects" (Result.is_error semantic_result);
 check "answered candidate state cleared" (Artifact_pressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate:(pressure target)=None);
 check "undated quota cleared" (not (Artifact_quota.is_exhausted ~scope:(quota target) ~now:(Unix.gettimeofday ()))));
case "capacity / network / local timeout never creates ownerless failed mark" (fun () ->
 let target=row "not-a-provider-failure" in
 List.iter (Artifact_standing.observe_http_error ~now:(Unix.gettimeofday ()) ~candidate:(pressure target) ~quota_scope:(quota target))
 [Artifact_boundary.Llm_provider.Http_client.ProviderFailure {kind=Capacity_exhausted ();message="provider capacity"};
  Artifact_boundary.Llm_provider.Http_client.TimeoutError "local queue timeout";
  Artifact_boundary.Llm_provider.Http_client.NetworkError "network refusal"];
 check "no Fleet mark invented" (Artifact_pressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate:(pressure target)=None);
 check "no hard quota invented" (not (Artifact_quota.is_exhausted ~scope:(quota target) ~now:(Unix.gettimeofday ()))));
Printf.printf "TOTAL %d cases passed\n" !tests
