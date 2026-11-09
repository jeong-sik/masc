(* test/test_auth_credential_optional_fields.ml

   #28159 — require_credential_optional_string answered key absence with
   Error "missing required field ..." instead of Ok None, so a credential
   JSON that simply omits id/agent_id/expires_at failed to load although
   the record declares all three as options ([@default None]). The
   production encoder (agent_credential_to_yojson) writes null for None,
   which is why the omission path had never executed anywhere. Pins both
   load paths and the required-field guard:

   1. optional keys omitted -> Ok, all three optional fields None
   2. optional keys present as explicit null (current encoder output)
      -> Ok, still loads
   3. a genuinely missing REQUIRED field (agent_name) is still rejected *)

let load json =
  Types_auth.agent_credential_of_yojson (Yojson.Safe.from_string json)

let expect_ok name json ~check =
  match load json with
  | Ok cred ->
    check cred;
    Printf.printf "PASS: %s\n" name
  | Error msg ->
    Printf.printf "FAIL: %s -> Error %s\n" name msg;
    exit 1

let expect_error name json ~fragment =
  match load json with
  | Ok _ ->
    Printf.printf "FAIL: %s -> Ok, expected Error\n" name;
    exit 1
  | Error msg ->
    if
      String.length msg < String.length fragment
      || String.sub msg 0 (String.length fragment) <> fragment
    then (
      Printf.printf "FAIL: %s -> Error %S, expected prefix %S\n" name msg fragment;
      exit 1);
    Printf.printf "PASS: %s\n" name

let required_fields =
  {|"agent_name":"keeper-x-agent","token":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","role":"worker","created_at":"2026-04-26T00:00:00Z"|}

let assert_optional_fields_none (cred : Types_auth.agent_credential) =
  assert (cred.Types_auth.id = None);
  assert (cred.Types_auth.agent_id = None);
  assert (cred.Types_auth.expires_at = None)

let test () =
  (* Case 1: keys omitted entirely. Before the fix this returned
     Error "agent_credential_of_yojson: missing required field \"id\"". *)
  expect_ok "optional keys omitted"
    (Printf.sprintf "{%s}" required_fields)
    ~check:assert_optional_fields_none;
  (* Case 2: explicit nulls — exactly what the production encoder emits
     for None fields, so existing files keep loading. *)
  expect_ok "optional keys present as null"
    (Printf.sprintf {|{"id":null,"agent_id":null,"expires_at":null,%s}|} required_fields)
    ~check:assert_optional_fields_none;
  (* Guard: the fix must not relax genuinely required fields. *)
  expect_error "missing required agent_name still rejected"
    {|{"token":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","role":"worker","created_at":"2026-04-26T00:00:00Z"}|}
    ~fragment:{|agent_credential_of_yojson: missing required field "agent_name"|}

let () = test ()
