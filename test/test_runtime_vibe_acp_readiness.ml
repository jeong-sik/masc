open Alcotest

(* The JSON below follows the field names vibe-acp 3.1.0 answered with
   (docs/evidence/vibe-official-client-lane-20261107/acp/). The values are
   made up: the bundle keeps only field names and kinds of account values. *)

module R = Runtime_vibe_acp_readiness

let json = Yojson.Safe.from_string

let ok_or_fail = function
  | Ok value -> value
  | Error error -> fail (R.error_to_string error)
;;

let account ?(status = "ready") ?(scope = {|{"preview":"x","scope":"vibe"}|}) ?(budget = "null") () =
  ok_or_fail
    (R.decode_account
       (json
          (Printf.sprintf
             {|{"status":%S,"plan":{"kind":"chat","name":"x","title":null},"apiKey":%s,"budget":%s,"teleportEligible":true}|}
             status
             scope
             budget)))
;;

let budget_at percent payg =
  Printf.sprintf {|{"usagePercentage":%s,"resetAt":null,"paygEnabled":%b}|} percent payg
;;

let signed_in ?(auth_state = R.Os_keyring) account = R.Signed_in { auth_state; account }

let reasons readiness =
  match R.verdict readiness with
  | Ok _ -> []
  | Error reasons -> List.map R.not_ready_to_string reasons
;;

let test_ready () =
  (match R.verdict (signed_in (account ~budget:(budget_at "12.5" true) ())) with
   | Ok (R.Known { usage_percentage; payg_enabled = true; _ }) ->
     check (float 0.) "budget" 12.5 usage_percentage
   | Ok R.Unknown | Ok (R.Known _) | Error _ -> fail "ready with a known budget");
  match R.verdict (signed_in (account ())) with
  | Ok R.Unknown -> ()
  | Ok (R.Known _) | Error _ -> fail "a null budget is ready with the budget unknown"
;;

(* Each case changes one input from the ready shape and must refuse with
   exactly that one reason. *)
let test_each_refusal () =
  let one name readiness expected =
    check (list string) name [ R.not_ready_to_string expected ] (reasons readiness)
  in
  one "signed out" (R.Not_signed_in R.Signed_out) (R.Not_authenticated R.Signed_out);
  List.iter
    (fun (name, state) -> one name (signed_in ~auth_state:state (account ())) (R.Credential_not_keyring state))
    [ ".env key", R.Vibe_home_env_file
    ; "process env key", R.Process_env
    ; "no key needed", R.Auth_not_required
    ; "unsupported provider", R.Unsupported_provider
    ];
  List.iter
    (fun (status, expected) -> one status (signed_in (account ~status ())) (R.Account_not_ready expected))
    [ "missing_key", R.Missing_key; "unauthorized", R.Unauthorized; "unavailable", R.Unavailable ];
  List.iter
    (fun (scope, expected) ->
      one
        scope
        (signed_in (account ~scope:(Printf.sprintf {|{"preview":"x","scope":%S}|} scope) ()))
        (R.Key_not_vibe_scope (Some expected)))
    [ "workspace", R.Workspace; "codestral", R.Codestral ];
  one "no apiKey" (signed_in (account ~scope:"null" ())) (R.Key_not_vibe_scope None);
  (* Past 100% the allowance is billed when pay-as-you-go is on and paused
     when it is off; the lane refuses both. *)
  List.iter
    (fun payg ->
      match R.verdict (signed_in (account ~budget:(budget_at "100" payg) ())) with
      | Error [ R.Budget_used_up { payg_enabled; _ } ] -> check bool "payg kept" payg payg_enabled
      | Ok _ | Error _ -> fail (Printf.sprintf "100%% used with payg %b must refuse" payg))
    [ true; false ];
  let nan_budget = { R.usage_percentage = Float.nan; reset_at = None; payg_enabled = false } in
  match R.verdict (signed_in { (account ()) with budget = Some nan_budget }) with
  | Error [ R.Budget_used_up _ ] -> ()
  | Ok _ | Error _ -> fail "a NaN budget refuses"
;;

let test_wire_values () =
  (match (ok_or_fail (R.decode_auth_status (json {|{"authenticated":true,"authState":"oidc_session"}|}))).auth_state with
   | R.Unrecognized_auth_state "oidc_session" -> ()
   | _ -> fail "an unknown authState keeps its value");
  (match (account ~scope:{|{"preview":"x","scope":"team"}|} ()).key_scope with
   | Some (R.Unrecognized_key_scope "team") -> ()
   | _ -> fail "an unknown scope keeps its value");
  check bool "missing authState is an error" true
    (Result.is_error (R.decode_auth_status (json {|{"authenticated":true}|})));
  check bool "a string budget is an error" true
    (Result.is_error (R.decode_account (json {|{"status":"ready","budget":"full"}|})))
;;

let () =
  run
    "runtime_vibe_acp_readiness"
    [ ( "verdict"
      , [ test_case "ready" `Quick test_ready; test_case "each refusal" `Quick test_each_refusal ] )
    ; "decode", [ test_case "wire values" `Quick test_wire_values ]
    ]
;;
