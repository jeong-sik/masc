(** test_keeper_chat_store_role_filter.ml — RFC-0232 P1

    Tests the Role.t typed role and role_filter integration in
    keeper_chat_store:

    - role_to_string / role_of_string round-trip
    - role_filter_matches correctly filters by role variant
    - load_page with ~role_filter (Roles [User]) returns only user messages
    - load_page with ~role_filter AllRoles returns everything
    - load defaults to AllRoles for backward compatibility *)

open Masc

let make_msg ~role ?(content = "hello") ?(ts = 1000.0) () =
  Keeper_chat_store.{
    role;
    content;
    ts = Some ts;
    source = None;
    speaker = None;
    tool_call_id = None;
    tool_call_name = None;
    tool_calls = None;
  }

(* ─── Role round-trip ───────────────────────────────────────────── *)

let test_role_round_trip () =
  let cases = [
    (User, "user");
    (Assistant, "assistant");
    (Tool, "tool");
  ] in
  List.iter (fun (r, expected) ->
    let s = Keeper_chat_store.role_to_string r in
    Alcotest.(check string) "role_to_string" expected s;
    let r_back = Keeper_chat_store.role_of_string s in
    Alcotest.(check (option (of_type (fun _ -> "role"))))
      "role_of_string round-trip" (Some r) r_back;
  ) cases;
  (* Unknown string -> None *)
  Alcotest.(check (option (of_type (fun _ -> "role"))))
    "role_of_string bad input" None
    (Keeper_chat_store.role_of_string "system");
  Alcotest.(check (option (of_type (fun _ -> "role"))))
    "role_of_string empty" None
    (Keeper_chat_store.role_of_string "");
  Alcotest.(check int) "3 cases" 3 (List.length cases)

(* ─── role_filter_matches ───────────────────────────────────────── *)

let test_role_filter_matches () =
  (* AllRoles matches everything *)
  Alcotest.(check bool) "AllRoles user" true
    (Keeper_chat_store.role_filter_matches AllRoles "user");
  Alcotest.(check bool) "AllRoles assistant" true
    (Keeper_chat_store.role_filter_matches AllRoles "assistant");
  Alcotest.(check bool) "AllRoles tool" true
    (Keeper_chat_store.role_filter_matches AllRoles "tool");
  Alcotest.(check bool) "AllRoles unknown" true
    (Keeper_chat_store.role_filter_matches AllRoles "system");

  (* Roles [User] matches only user *)
  let filter = Roles [User] in
  Alcotest.(check bool) "Roles[User] user" true
    (Keeper_chat_store.role_filter_matches filter "user");
  Alcotest.(check bool) "Roles[User] assistant" false
    (Keeper_chat_store.role_filter_matches filter "assistant");
  Alcotest.(check bool) "Roles[User] tool" false
    (Keeper_chat_store.role_filter_matches filter "tool");

  (* Roles [User; Assistant] matches both *)
  let filter2 = Roles [User; Assistant] in
  Alcotest.(check bool) "Roles[U+A] user" true
    (Keeper_chat_store.role_filter_matches filter2 "user");
  Alcotest.(check bool) "Roles[U+A] assistant" true
    (Keeper_chat_store.role_filter_matches filter2 "assistant");
  Alcotest.(check bool) "Roles[U+A] tool" false
    (Keeper_chat_store.role_filter_matches filter2 "tool");

  (* Unknown role string with Roles filter -> false *)
  Alcotest.(check bool) "Roles[U] unknown" false
    (Keeper_chat_store.role_filter_matches filter "system")

(* ─── append_message typed role ─────────────────────────────────── *)

let test_append_typed_role () =
  let base_dir = Filename.concat (Sys.getenv "TEST_TMPDIR" |> Option.value ~default:"/tmp") "role_test" in
  let keeper_name = "role-test-keeper" in
  (* Clean slate *)
  (try Fs_compat.rm_rf base_dir with _ -> ());

  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:User
    ~content:"user says hi" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:Assistant
    ~content:"assistant replies" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:Tool
    ~content:"{\"result\":\"ok\"}" ?tool_call_id:(Some "tc_1")
    ?tool_call_name:(Some "TestTool") ();

  let all = Keeper_chat_store.load ~base_dir ~keeper_name () in
  Alcotest.(check int) "3 messages written+loaded" 3 (List.length all);
  Alcotest.(check string) "msg[0] role user" "user" (List.nth all 0).role;
  Alcotest.(check string) "msg[1] role assistant" "assistant" (List.nth all 1).role;
  Alcotest.(check string) "msg[2] role tool" "tool" (List.nth all 2).role;

  (* Cleanup *)
  (try Fs_compat.rm_rf base_dir with _ -> ())

(* ─── load_page with ~role_filter ───────────────────────────────── *)

let test_load_page_role_filter () =
  let base_dir = Filename.concat (Sys.getenv "TEST_TMPDIR" |> Option.value ~default:"/tmp") "role_filter_test" in
  let keeper_name = "role-filter-keeper" in
  (try Fs_compat.rm_rf base_dir with _ -> ());

  (* Append interleaved messages: U, A, U, A, T, U *)
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:User
    ~content:"first user" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:Assistant
    ~content:"first assistant" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:User
    ~content:"second user" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:Assistant
    ~content:"second assistant" ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:Tool
    ~content:"{}" ?tool_call_id:(Some "tc_1") ?tool_call_name:(Some "Test") ();
  Keeper_chat_store.append_message ~base_dir ~keeper_name ~role:User
    ~content:"third user" ();

  (* Load with filter: only user messages *)
  let page = Keeper_chat_store.load_page ~base_dir ~keeper_name
    ~role_filter:(Roles [User]) () in
  Alcotest.(check bool) "user-only page has_more" false page.has_more;
  Alcotest.(check int) "user-only count" 3 (List.length page.messages);
  List.iter (fun m ->
    Alcotest.(check string) "all messages are user" "user" m.role
  ) page.messages;

  (* Load with filter: only assistant messages *)
  let page_a = Keeper_chat_store.load_page ~base_dir ~keeper_name
    ~role_filter:(Roles [Assistant]) () in
  Alcotest.(check int) "assistant-only count" 2 (List.length page_a.messages);
  List.iter (fun m ->
    Alcotest.(check string) "all messages are assistant" "assistant" m.role
  ) page_a.messages;

  (* Load with filter: AllRoles = same as default *)
  let page_all = Keeper_chat_store.load_page ~base_dir ~keeper_name
    ~role_filter:AllRoles () in
  Alcotest.(check int) "all-roles count" 6 (List.length page_all.messages);

  (* Load without filter (backward compat) returns everything *)
  let page_default = Keeper_chat_store.load_page ~base_dir ~keeper_name () in
  Alcotest.(check int) "default count same as all" 6 (List.length page_default.messages);

  (* Cleanup *)
  (try Fs_compat.rm_rf base_dir with _ -> ())

let () =
  Alcotest.run "keeper_chat_store_role_filter"
    [ ("role_round_trip", [
        Alcotest.test_case "role_to_string / role_of_string" `Quick test_role_round_trip;
      ]);
      ("role_filter_matches", [
        Alcotest.test_case "role_filter_matches" `Quick test_role_filter_matches;
      ]);
      ("append_typed_role", [
        Alcotest.test_case "append_message with typed role" `Quick test_append_typed_role;
      ]);
      ("load_page_role_filter", [
        Alcotest.test_case "load_page with ~role_filter" `Quick test_load_page_role_filter;
      ]);
    ]