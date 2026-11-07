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

let auth state = ok_or_fail (R.decode_auth_status (json state))

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

let keyring = {|{"authenticated":true,"authState":"os_keyring","signOutAvailable":true}|}
let budget_at percent = Printf.sprintf {|{"usagePercentage":%g,"resetAt":null,"paygEnabled":true}|} percent

let reasons readiness =
  match R.verdict readiness with
  | Ok _ -> []
  | Error reasons -> reasons
;;

let test_ready () =
  (match R.verdict { auth = auth keyring; account = account ~budget:(budget_at 12.5) () } with
   | Ok (R.Known { usage_percentage; payg_enabled = true; _ }) ->
     check (float 0.) "budget" 12.5 usage_percentage
   | Ok R.Unknown | Ok (R.Known _) | Error _ -> fail "ready with a known budget");
  match R.verdict { auth = auth keyring; account = account () } with
  | Ok R.Unknown -> ()
  | Ok (R.Known _) | Error _ -> fail "a null budget is ready with the budget unknown"
;;

let test_not_ready () =
  (match reasons { auth = auth {|{"authenticated":false,"authState":"signed_out"}|}; account = account ~status:"missing_key" ~scope:"null" () } with
   | [ R.Not_authenticated R.Signed_out; R.Account_not_ready R.Missing_key; R.Key_not_vibe_scope None ] -> ()
   | other -> fail (String.concat "; " (List.map R.not_ready_to_string other)));
  (match reasons { auth = auth {|{"authenticated":true,"authState":"vibe_home_env_file"}|}; account = account ~status:"unauthorized" () } with
   | [ R.Credential_not_from_keyring R.Vibe_home_env_file; R.Account_not_ready R.Unauthorized ] -> ()
   | other -> fail (String.concat "; " (List.map R.not_ready_to_string other)));
  (* Past 100% the allowance is billed when pay-as-you-go is on; the lane
     refuses either way. *)
  match reasons { auth = auth keyring; account = account ~budget:(budget_at 100.) () } with
  | [ R.Budget_used_up { payg_enabled = true; _ } ] -> ()
  | other -> fail (String.concat "; " (List.map R.not_ready_to_string other))
;;

let test_wire_values () =
  (match (auth {|{"authenticated":true,"authState":"oidc_session"}|}).auth_state with
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
      , [ test_case "ready" `Quick test_ready; test_case "not ready" `Quick test_not_ready ] )
    ; "decode", [ test_case "wire values" `Quick test_wire_values ]
    ]
;;
