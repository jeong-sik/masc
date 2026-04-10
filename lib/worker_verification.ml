(** Worker_verification — cross-agent verification for worker outputs.

    Wraps worker run_results in OAS Verified_output and uses
    verifier_oas (cheap model) for independent verification.
    The verifier is a separate agent from the producer — no self-verification.

    @since Phase 3-D — OAS Verified_output integration *)

type verified_result = {
  run_result : Worker_container_types.run_result;
  verified_output : Oas.Verified_output.verified Oas.Verified_output.output;
  verifier_verdict : Verifier_oas.verdict;
}

type verification_outcome =
  | Verified of verified_result
  | Unverified of {
      run_result : Worker_container_types.run_result;
      reason : string;
      verifier_verdict : Verifier_oas.verdict option;
    }

let verify_worker_result
    ~(goal : string)
    (run_result : Worker_container_types.run_result)
    : verification_outcome =
  match run_result.api_response with
  | None ->
    Unverified
      {
        run_result;
        reason = "no api_response available (legacy runner)";
        verifier_verdict = None;
      }
  | Some response ->
    let unverified = Oas.Verified_output.of_response
      ~producer:run_result.model_used response in
    let contract_goal = goal in
    let req : Verifier_oas.verification_request = {
      action_description = Printf.sprintf "Worker %s produced output"
        run_result.model_used;
      action_result = run_result.output;
      goal = contract_goal;
      context_summary = Printf.sprintf "model=%s tokens_in=%s tokens_out=%s"
        run_result.model_used
        (Option.fold ~none:"?" ~some:string_of_int run_result.input_tokens)
        (Option.fold ~none:"?" ~some:string_of_int run_result.output_tokens);
    } in
    let verdict = Verifier_oas.verify req in
    match verdict with
    | Ok Verifier_oas.Pass ->
      let verified = Oas.Verified_output.verify unverified
        ~verifier:"verifier_oas"
        ~confidence:0.9
        ~evidence:"cheap_model_pass" in
      (match verified with
       | Some v ->
           Verified
             {
               run_result;
               verified_output = v;
               verifier_verdict = Verifier_oas.Pass;
             }
       | None ->
           Unverified
             {
               run_result;
               reason = "verification threshold not met";
               verifier_verdict = Some Verifier_oas.Pass;
             })
    | Ok (Verifier_oas.Warn reason) ->
      let verified = Oas.Verified_output.verify unverified
        ~verifier:"verifier_oas"
        ~confidence:0.6
        ~evidence:(Printf.sprintf "cheap_model_warn: %s" reason) in
      (match verified with
       | Some v ->
           Verified
             {
               run_result;
               verified_output = v;
               verifier_verdict = Verifier_oas.Warn reason;
             }
       | None ->
           Unverified
             {
               run_result;
               reason;
               verifier_verdict = Some (Verifier_oas.Warn reason);
             })
    | Ok (Verifier_oas.Fail reason) ->
      Unverified
        {
          run_result;
          reason;
          verifier_verdict = Some (Verifier_oas.Fail reason);
        }
    | Error reason ->
      Unverified
        {
          run_result;
          reason = Printf.sprintf "verifier_error: %s" reason;
          verifier_verdict = None;
        }

let text_of_outcome = function
  | Verified vr -> Oas.Verified_output.text vr.verified_output
  | Unverified { run_result; _ } -> run_result.output

let is_verified = function
  | Verified _ -> true
  | Unverified _ -> false
