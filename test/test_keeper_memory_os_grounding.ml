(* RFC-0259 P2: unit tests for the observe-only grounding reconciler. Pure,
   deterministic, no network — verify_external is faked, and the GitHub response
   parser is exercised on canned JSON. *)

module Types = Masc.Keeper_memory_os_types
module Grounding = Masc.Keeper_memory_os_grounding

let failed = ref 0

let check name cond =
  if cond then Printf.printf "[PASS] %s\n%!" name
  else (
    incr failed;
    Printf.printf "[FAIL] %s\n%!" name)

let mk_fact ?(external_ref = None) ?(first_seen = 0.0) ?last_verified_at ~claim () : Types.fact =
  { Types.claim
  ; Types.category = Types.Fact
  ; Types.external_ref
  ; Types.source = { Types.trace_id = "t"; Types.turn = 1; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen
  ; Types.valid_until = None
  ; Types.last_verified_at
  ; Types.schema_version = Types.schema_version
  }
;;

let pr_body state =
  Printf.sprintf {|{"data":{"repository":{"pullRequest":{"state":"%s"}}}}|} state
;;

let () =
  (* ---- parse_state_response ---- *)
  check
    "parse OPEN"
    (Grounding.parse_state_response ~kind:Types.Pr (pr_body "OPEN") = Ok Grounding.Open);
  check
    "parse CLOSED"
    (Grounding.parse_state_response ~kind:Types.Pr (pr_body "CLOSED") = Ok Grounding.Closed);
  check
    "parse MERGED"
    (Grounding.parse_state_response ~kind:Types.Pr (pr_body "MERGED") = Ok Grounding.Merged);
  check
    "parse issue CLOSED"
    (Grounding.parse_state_response
       ~kind:Types.Issue
       {|{"data":{"repository":{"issue":{"state":"CLOSED"}}}}|}
     = Ok Grounding.Closed);
  check
    "parse null node -> Not_found"
    (Grounding.parse_state_response
       ~kind:Types.Pr
       {|{"data":{"repository":{"pullRequest":null}}}|}
     = Ok Grounding.Not_found);
  check
    "parse graphql errors -> Error (Indeterminate)"
    (Result.is_error
       (Grounding.parse_state_response
          ~kind:Types.Pr
          {|{"errors":[{"message":"bad"}]}|}));
  check
    "parse unknown state -> Error"
    (Result.is_error
       (Grounding.parse_state_response
          ~kind:Types.Pr
          (pr_body "DRAFTED")));
  check
    "parse garbage -> Error"
    (Result.is_error (Grounding.parse_state_response ~kind:Types.Pr "not json"));
  (* ---- classify_state ---- *)
  check "classify Open -> Confirmed" (Grounding.classify_state Grounding.Open = Grounding.Confirmed);
  check
    "classify Closed -> Contradicted_candidate"
    (Grounding.classify_state Grounding.Closed = Grounding.Contradicted_candidate);
  check
    "classify Merged -> Contradicted_candidate"
    (Grounding.classify_state Grounding.Merged = Grounding.Contradicted_candidate);
  check
    "classify Not_found -> Indeterminate"
    (Grounding.classify_state Grounding.Not_found = Grounding.Indeterminate);
  (* ---- grounding_pass (fake verify_external, no network) ---- *)
  let horizon = 1000.0 in
  let now = 100_000.0 in
  let pr_ref = Some { Types.kind = Types.Pr; Types.id = "21363" } in
  let fake : Grounding.verify_external =
    fun r -> if String.equal r.Types.id "21363" then Ok Grounding.Closed else Error "unknown"
  in
  let stale_volatile =
    mk_fact ~external_ref:pr_ref ~first_seen:(now -. (horizon *. 2.0)) ~claim:"PR #21363 is OPEN" ()
  in
  let fresh_volatile =
    mk_fact ~external_ref:pr_ref ~first_seen:(now -. (horizon /. 2.0)) ~claim:"PR #21363 is OPEN" ()
  in
  let non_volatile =
    mk_fact ~external_ref:None ~first_seen:(now -. (horizon *. 2.0)) ~claim:"durable knowledge" ()
  in
  let obs =
    Grounding.grounding_pass
      ~verify_external:fake
      ~now
      ~grounding_horizon:horizon
      ~keeper_id:"k"
      [ stale_volatile; fresh_volatile; non_volatile ]
  in
  check "only the stale volatile fact is observed" (List.length obs = 1);
  (match obs with
   | [ o ] ->
     check
       "verdict is contradicted_candidate (CLOSED)"
       (o.Grounding.verdict = Grounding.Contradicted_candidate);
     check "fetched state is Closed" (o.Grounding.fetched = Ok Grounding.Closed);
     check
       "normalized claim preserved (P3 retraction key)"
       (String.equal o.Grounding.normalized_claim (Types.normalize_claim "PR #21363 is OPEN"))
   | _ -> check "exactly one observation" false);
  (* age uses last_verified_at when present: an old first_seen but recent
     re-verification keeps the fact under the horizon (excluded). *)
  let reverified =
    mk_fact
      ~external_ref:pr_ref
      ~first_seen:(now -. (horizon *. 5.0))
      ~last_verified_at:(now -. (horizon /. 2.0))
      ~claim:"PR #21363 is OPEN"
      ()
  in
  check
    "recently re-verified volatile fact is excluded (age anchors on last_verified_at)"
    (List.length
       (Grounding.grounding_pass
          ~verify_external:fake
          ~now
          ~grounding_horizon:horizon
          ~keeper_id:"k"
          [ reverified ])
     = 0);
  (* verify_external Error collapses to Indeterminate, never a false verdict. *)
  let err_fake : Grounding.verify_external = fun _ -> Error "boom" in
  (match
     Grounding.grounding_pass
       ~verify_external:err_fake
       ~now
       ~grounding_horizon:horizon
       ~keeper_id:"k"
       [ stale_volatile ]
   with
   | [ o ] ->
     check "verify Error -> Indeterminate verdict" (o.Grounding.verdict = Grounding.Indeterminate)
   | _ -> check "one observation for the error path" false);
  (* no_token_verify degrades every ref to Error (-> Indeterminate). *)
  check
    "no_token_verify is always Error"
    (Result.is_error (Grounding.no_token_verify { Types.kind = Types.Pr; Types.id = "1" }));
  if !failed > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failed;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
;;
