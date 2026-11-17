open Alcotest
open Masc
module Remote = Keeper_sandbox_remote
module Request = Remote.Stdio_request

let get = function Ok value -> value | Error _ -> fail "fixture operation refused"
let argv = ["reader-program"; ""; "  exact argument  "]
let keeper_name = "binding-reader"

let with_base f =
  let base = Unix.realpath (Filename.temp_dir "stdio-binding-" "") in
  Fun.protect ~finally:(fun () -> Unix.rmdir base) (fun () -> f base)

let guest ?(connect = 1) ?(sessions = 1) base =
  Remote.of_agent_socket ~base_path:base ~keeper_name ~remote_root:"/work"
    ~gh_config_dir:"/control/gh" ~injected_env:[] ~env_allowlist:["VALUE"]
    ~connect_timeout_sec:connect ~max_concurrent_sessions:sessions
    ~container_name:"reader-guest" ~shim_path:"/bin/masc-exec-shim"
    ~host_socket:(Filename.concat base "absent.sock")
    ~expected:{Keeper_guest_socket.uid=1000; gid=1000}

let process ?(connect = 1) base =
  Remote.of_container_exec ~base_path:base ~keeper_name ~remote_root:"/work"
    ~gh_config_dir:"/control/gh" ~injected_env:[] ~env_allowlist:[]
    ~connect_timeout_sec:connect ~max_concurrent_sessions:1
    {prefix=["never-spawned-carrier"];probe_prefix=None;
     container_name="reader-guest";shim_path="/bin/masc-exec-shim"}

let prepare ?(env = [||]) endpoint =
  get (Request.prepare ~timeout_sec:15. endpoint ~argv ~env ~cwd:None)

let binding base prepared =
  get (Request.binding prepared ~base_path:base ~keeper_name ~expected_argv:argv)

let canonical json = get (Lane_addon_action.canonical json)

let changed_field key value = function
  | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    fail "fixture expected a JSON object"

let expect_bad_binding json =
  match Request.binding_of_json json with
  | Error _ -> () | Ok _ -> fail "invalid retained binding was accepted"

let test_prepared_recipe_survives_storage_and_input_mutation () =
  with_base @@ fun base ->
  let env = [|"VALUE=original"|] in
  let prepared = prepare ~env (guest base) in
  let captured = binding base prepared in
  env.(0) <- "VALUE=changed";
  let wire = Request.binding_to_json captured |> canonical |> Yojson.Safe.to_string in
  let restored = get (Request.binding_of_json (Yojson.Safe.from_string wire)) in
  check bool "canonical store numbers preserve the same prepared recipe" true
    (Request.matches_binding prepared restored);
  check bool "mutable input array does not change the captured frame" true
    (binding base prepared = captured);
  check bool "a newly prepared different input has a different identity" false
    (Request.matches_binding (prepare ~env (guest base)) captured);
  check bool "endpoint admission policy belongs to the recipe" false
    (Request.matches_binding (prepare ~env:[|"VALUE=original"|] (guest ~sessions:2 base)) captured);
  check bool "another Keeper cannot borrow the recipe" true
    (Request.validate_binding restored ~base_path:base ~keeper_name:"other"
       ~expected_argv:argv = Error Request.Owner_mismatch);
  check bool "declaration argv must match exactly" true
    (Request.validate_binding restored ~base_path:base ~keeper_name
       ~expected_argv:["reader-program"; "exact argument"] = Error Request.Payload_argv_mismatch);
  check bool "another workspace cannot capture it" true
    (Request.binding prepared ~base_path:(Filename.concat base "other") ~keeper_name
       ~expected_argv:argv = Error Request.Owner_mismatch);
  check bool "recipe capture did not require an existing guest socket" false
    (Sys.file_exists (Filename.concat base "absent.sock"))

let contains text needle =
  let rec at offset =
    offset + String.length needle <= String.length text
    && (String.sub text offset (String.length needle) = needle || at (offset+1)) in
  at 0

let test_carrier_environment_is_captured_without_plaintext () =
  with_base @@ fun base ->
  let old = Sys.getenv_opt "PAGER" in
  Fun.protect ~finally:(fun () -> match old with
    | Some value -> Unix.putenv "PAGER" value
    | None -> Unix.unsetenv "PAGER") (fun () ->
    (* PAGER is an actually inherited carrier variable; no process runs. *)
    let before = "binding-fixture-private-before" in
    Unix.putenv "PAGER" before;
    let first = prepare (process base) in
    let captured = binding base first in
    Unix.putenv "PAGER" "binding-fixture-private-after";
    check bool "reading an old recipe never rereads ambient environment" true
      (binding base first = captured);
    check bool "a fresh prepare observes changed carrier environment" false
      (Request.matches_binding (prepare (process base)) captured);
    check bool "carrier environment values are absent from serialized binding" false
      (contains (Yojson.Safe.to_string (Request.binding_to_json captured)) before))

let test_strict_retained_shape_and_real_budget_boundary () =
  with_base @@ fun base ->
  let prepared = prepare (guest base) in
  let json = Request.binding_to_json (binding base prepared) |> canonical in
  List.iter (fun value -> expect_bad_binding (changed_field "budget_sec" value json))
    [`Int 0; `Int (-1); `Float infinity; `Float nan;
     `Intlit "9007199254740993"; `String "20"];
  expect_bad_binding (changed_field "frame_sha256" (`String "not-a-digest") json);
  expect_bad_binding (changed_field "frame_bytes" (`Int 0) json);
  (match json with
   | `Assoc fields ->
     expect_bad_binding (`Assoc (("schema",`String "keeper-stdio-binding.v1") :: fields));
     expect_bad_binding (`Assoc (("unknown",`Null) :: fields));
     expect_bad_binding (`Assoc (List.remove_assoc "payload_argv" fields))
   | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
     fail "fixture expected a canonical binding object");
  List.iter (fun endpoint ->
    match Request.prepare ~timeout_sec:1. endpoint ~argv ~env:[||] ~cwd:None with
    | Error (Request.Invalid_request _) -> ()
    | Error (Request.Docker_unavailable | Request.Mode_unavailable _ | Request.Probe_unavailable _
        | Request.Interactive_unavailable _) | Ok _ ->
      fail "invalid actual host or guest connection budget was prepared")
    [guest ~connect:0 base; process ~connect:(-10) base]

let () =
  Alcotest.run "prepared stdio invocation binding"
    ["capture",
      [test_case "prepared input and canonical retention" `Quick
         test_prepared_recipe_survives_storage_and_input_mutation;
       test_case "carrier environment snapshot and plaintext exclusion" `Quick
         test_carrier_environment_is_captured_without_plaintext;
       test_case "strict retained data and existing execution budgets" `Quick
         test_strict_retained_shape_and_real_budget_boundary]]
