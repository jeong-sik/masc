(* Removing a sign-in the operator no longer wants: the provider and its
   binding tables go, everything that routed to its runtimes stops naming
   them, and every other line stays as the operator wrote it. *)

module R = Runtime_account_removal
module S = Runtime_schema

let fixture =
  {|# operator note kept verbatim
[runtime]
default = "codex_subscription.gpt-5.6"
media_failover = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"]

[runtime.lanes.coding]
candidates = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"]

[runtime.exact_output_lanes.verifier_exact]
slots = ["codex_subscription.gpt-5.6"]
cli_slots = ["codex_acct1.gpt-5.6"]

[runtime.assignments]
tester = "codex_acct1.gpt-5.6"
other = "codex_subscription.gpt-5.6"
by_lane = "coding"

[providers.codex_subscription]
display-name = "Codex"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

# the account the review team signs in with
[providers.codex_acct1]
display-name = "Codex · account1"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/home/op/.codex-account1"

[providers.antigravity_subscription]
display-name = "Antigravity"
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 180.0

[providers.antigravity_subscription.credentials]
type = "file"
path = "/home/op/.gemini/antigravity-oauth-token"

[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[models.flash]
api-name = "gemini-3.7-flash-high"
max-context = 1000000
tools-support = true

[models.local-model]
api-name = "local"
max-context = 32000
tools-support = true

[codex_subscription."gpt-5.6"]
max-concurrent = 2

[codex_acct1."gpt-5.6"]
max-concurrent = 1

[antigravity_subscription.flash]

[ollama.local-model]
|}

let replace ~sub ~by text =
  match Str.search_forward (Str.regexp_string sub) text 0 with
  | exception Not_found -> Alcotest.failf "the fixture has no %S" sub
  | at -> String.sub text 0 at ^ by ^ String.sub text (at + String.length sub) (String.length text - at - String.length sub)

let contains ~sub text =
  match Str.search_forward (Str.regexp_string sub) text 0 with
  | exception Not_found -> false
  | _ -> true

let shared_model_declarations =
  {|[models."gpt-5.6-high"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true
reasoning-effort = "high"

[model_sets.codex]
models = ["gpt-5.6", "gpt-5.6-high"]
|}

let shared_fixture =
  fixture
  |> replace ~sub:"[providers.codex_subscription]\n"
       ~by:"[providers.codex_subscription]\nmodel-set = \"codex\"\n"
  |> replace ~sub:"[providers.codex_acct1]\n"
       ~by:"[providers.codex_acct1]\nmodel-set = \"codex\"\n"
  |> replace ~sub:"[codex_subscription.\"gpt-5.6\"]\nmax-concurrent = 2\n" ~by:""
  |> replace ~sub:"[codex_acct1.\"gpt-5.6\"]\nmax-concurrent = 1\n" ~by:""
  |> fun text ->
  text ^ "\n" ^ shared_model_declarations
  ^ {|
[runtime.lanes.high]
candidates = ["codex_acct1.gpt-5.6-high", "codex_subscription.gpt-5.6-high"]
|}

let show_change = function
  | R.Table path -> "table " ^ path
  | R.Lane_candidate { lane; runtime } -> Printf.sprintf "lane %s: %s" lane runtime
  | R.Exact_lane_slot { lane; runtime } -> Printf.sprintf "exact lane %s: %s" lane runtime
  | R.Vision_runtime runtime -> "vision " ^ runtime
  | R.Assignment { keeper; runtime } -> Printf.sprintf "keeper %s: %s" keeper runtime

let removed ?(text = fixture) id =
  match R.remove text ~id with
  | Ok removed -> removed
  | Error e -> Alcotest.failf "%s was not removed: %s" id (R.error_message e)

let refused ?(text = fixture) id =
  match R.remove text ~id with
  | Ok { R.changes; _ } ->
    Alcotest.failf "%s was removed: %s" id (String.concat ", " (List.map show_change changes))
  | Error e -> e

let loaded text =
  match Runtime_toml.parse_string text with
  | Ok config -> config
  | Error _ -> Alcotest.fail "the text without the account does not load"

let lane config id =
  match List.find_opt (fun (lane : S.lane_decl) -> lane.id = id) config.S.lane_decls with
  | Some lane -> lane.candidate_ids
  | None -> Alcotest.failf "lane %s is gone" id

let test_the_account_and_what_routes_to_it_go () =
  let { R.text; changes; login_store } = removed "codex_acct1" in
  Alcotest.(check (list string)) "what changed, in order"
    [ "table providers.codex_acct1"
    ; "table codex_acct1.\"gpt-5.6\""
    ; "lane coding: codex_acct1.gpt-5.6"
    ; "exact lane verifier_exact: codex_acct1.gpt-5.6"
    ; "vision codex_acct1.gpt-5.6"
    ; "keeper tester: codex_acct1.gpt-5.6"
    ]
    (List.map show_change changes);
  Alcotest.(check (option string)) "the login store is reported, not removed"
    (Some "/home/op/.codex-account1") login_store;
  let config = loaded text in
  Alcotest.(check bool) "the provider is gone" false
    (List.exists (fun (p : S.provider) -> p.id = "codex_acct1") config.providers);
  Alcotest.(check bool) "its binding is gone" false
    (List.exists (fun (b : S.binding) -> b.provider_id = "codex_acct1") config.bindings);
  Alcotest.(check (list string)) "the lane keeps its other candidate"
    [ "codex_subscription.gpt-5.6" ] (lane config "coding");
  (match config.exact_output_lane_decls with
   | [ verifier ] ->
     Alcotest.(check (list string)) "the exact lane keeps its slot"
       [ "codex_subscription.gpt-5.6" ] verifier.slot_ids;
     Alcotest.(check (list string)) "and loses the cli slot" [] verifier.cli_slot_ids
   | lanes -> Alcotest.failf "%d exact lanes" (List.length lanes));
  Alcotest.(check (list string)) "the vision list keeps the other runtime"
    [ "codex_subscription.gpt-5.6" ] config.media_failover;
  Alcotest.(check (list (pair string string))) "the other assignments stay"
    [ "other", "codex_subscription.gpt-5.6"; "by_lane", "coding" ]
    config.keeper_assignments;
  List.iter
    (fun line ->
      Alcotest.(check bool) ("kept verbatim: " ^ line) true (contains ~sub:line text))
    [ "# operator note kept verbatim"
    ; "[providers.codex_subscription]\ndisplay-name = \"Codex\""
    ; "[providers.antigravity_subscription.credentials]"
    ; "[codex_subscription.\"gpt-5.6\"]\nmax-concurrent = 2"
    ; "by_lane = \"coding\""
    ]

(* The OAuth file is the Antigravity login store, and its credentials table
   goes with the provider even when it is written apart from it. *)
let test_an_antigravity_account_takes_its_credentials_table () =
  let apart =
    replace
      ~sub:{|[providers.antigravity_subscription.credentials]
type = "file"
path = "/home/op/.gemini/antigravity-oauth-token"
|}
      ~by:"" fixture
    ^ {|
[providers.antigravity_subscription.credentials]
type = "file"
path = "/home/op/.gemini/antigravity-oauth-token"
|}
  in
  List.iter
    (fun (layout, text, tables) ->
      let { R.text = without; changes; login_store } = removed ~text "antigravity_subscription" in
      Alcotest.(check (list string)) ("tables removed: " ^ layout) tables
        (List.map show_change changes);
      Alcotest.(check (option string)) ("the OAuth file: " ^ layout)
        (Some "/home/op/.gemini/antigravity-oauth-token") login_store;
      Alcotest.(check bool) ("no credentials table is left: " ^ layout) false
        (contains ~sub:"antigravity_subscription.credentials" without))
    [ ( "beside its provider"
      , fixture
      , [ "table providers.antigravity_subscription"; "table antigravity_subscription.flash" ] )
    ; ( "apart from its provider"
      , apart
      , [ "table providers.antigravity_subscription"
        ; "table providers.antigravity_subscription.credentials"
        ; "table antigravity_subscription.flash"
        ] )
    ]

let test_accounts_using_a_shared_model_set_are_removed () =
  List.iter
    (fun (layout, source, expected_tables) ->
      let before = loaded source in
      let { R.text; changes; _ } = removed ~text:source "codex_acct1" in
      let after = loaded text in
      Alcotest.(check (list string)) (layout ^ ": only source tables removed")
        expected_tables
        (List.filter_map
           (function R.Table path -> Some path | _ -> None)
           changes);
      Alcotest.(check bool) (layout ^ ": account bindings gone") false
        (List.exists (fun (b : S.binding) -> b.provider_id = "codex_acct1") after.bindings);
      Alcotest.(check (list string)) (layout ^ ": generated routes removed")
        [ "codex_subscription.gpt-5.6-high" ] (lane after "high");
      Alcotest.(check bool) (layout ^ ": shared model specifications unchanged") true
        (before.models = after.models);
      Alcotest.(check bool) (layout ^ ": shared model declarations kept verbatim") true
        (contains ~sub:shared_model_declarations text);
      Alcotest.(check bool) (layout ^ ": other provider bindings unchanged") true
        (List.filter (fun (b : S.binding) -> b.provider_id <> "codex_acct1") before.bindings
         = after.bindings))
    [ "generated bindings", shared_fixture, [ "providers.codex_acct1" ]
    ; ( "generated bindings with an explicit override"
      , shared_fixture ^ "\n[codex_acct1.\"gpt-5.6\"]\nmax-concurrent = 1\n"
      , [ "providers.codex_acct1"; "codex_acct1.\"gpt-5.6\"" ] )
    ]

let test_what_has_no_replacement_is_refused () =
  let cases =
    [ ( "the default"
      , replace ~sub:{|default = "codex_subscription.gpt-5.6"|}
          ~by:{|default = "codex_acct1.gpt-5.6"|} fixture
      , R.Default_runtime "codex_acct1.gpt-5.6" )
    ; ( "a lane with no other candidate"
      , fixture ^ "\n[runtime.lanes.solo]\ncandidates = [\"codex_acct1.gpt-5.6\"]\n"
      , R.Lane_emptied "solo" )
    ; ( "an exact lane with no other slot"
      , fixture
        ^ "\n[runtime.exact_output_lanes.hitl_auto_judge]\nslots = []\ncli_slots = [\"codex_acct1.gpt-5.6\"]\n"
      , R.Exact_lane_emptied "hitl_auto_judge" )
    ]
  in
  List.iter
    (fun (what, text, expected) ->
      let e = refused ~text "codex_acct1" in
      Alcotest.(check string) what (R.error_message expected) (R.error_message e))
    cases

(* A default or an assignment names a lane before a runtime, so a lane
   spelled like one of the account's runtimes is not the account's. *)
let test_a_lane_named_like_its_runtime_keeps_its_routes () =
  let text =
    replace ~sub:"by_lane = \"coding\"" ~by:"by_lane = \"coding\"\npinned = \"codex_acct1.gpt-5.6\"" fixture
    ^ "\n[runtime.lanes.\"codex_acct1.gpt-5.6\"]\ncandidates = [\"codex_subscription.gpt-5.6\"]\n"
  in
  let { R.text; changes; _ } = removed ~text "codex_acct1" in
  Alcotest.(check bool) "the assignment to the lane is not listed" false
    (List.mem "keeper pinned: codex_acct1.gpt-5.6" (List.map show_change changes));
  Alcotest.(check (option string)) "and stays" (Some "codex_acct1.gpt-5.6")
    (List.assoc_opt "pinned" (loaded text).keeper_assignments)

let test_a_layout_the_line_editor_cannot_reach_is_refused () =
  let cases =
    [ ( "a lane written inline"
      , replace
          ~sub:{|[runtime.lanes.coding]
candidates = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"]|}
          ~by:{|[runtime.lanes]
coding = { candidates = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"] }|}
          fixture )
    ; ( "assignments written as dotted keys"
      , replace
          ~sub:{|[runtime.assignments]
tester = "codex_acct1.gpt-5.6"
other = "codex_subscription.gpt-5.6"
by_lane = "coding"
|}
          ~by:""
          (replace ~sub:"[runtime]\n"
             ~by:"[runtime]\nassignments.tester = \"codex_acct1.gpt-5.6\"\nassignments.by_lane = \"coding\"\n"
             fixture) )
    ; ( "a provider written inline"
      , replace
          ~sub:{|[providers.codex_acct1]
display-name = "Codex · account1"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/home/op/.codex-account1"|}
          ~by:{|[providers]
codex_acct1 = { display-name = "Codex · account1", protocol = "codex-app-server", command = "codex", is-non-interactive = true, account-home = "/home/op/.codex-account1" }|}
          fixture )
    ; ( "an explicit binding written inline beside generated bindings"
      , shared_fixture ^ "\n[codex_acct1]\n\"gpt-5.6\" = { max-concurrent = 1 }\n" )
    ; ( "an explicit binding written as a dotted key beside generated bindings"
      , shared_fixture ^ "\n[codex_acct1]\n\"gpt-5.6\".max-concurrent = 1\n" )
    ]
  in
  List.iter
    (fun (what, text) ->
      (match Runtime_toml.parse_string text with
       | Ok _ -> ()
       | Error _ -> Alcotest.failf "the %s fixture does not load" what);
      match refused ~text "codex_acct1" with
      | R.Unsupported_layout _ -> ()
      | e -> Alcotest.failf "%s: %s" what (R.error_message e))
    cases

let test_only_an_official_client_account_is_removed () =
  List.iter
    (fun id ->
      match refused id with
      | R.Unknown_account found -> Alcotest.(check string) "the id" id found
      | e -> Alcotest.failf "%s: %s" id (R.error_message e))
    [ "ollama"; "nobody" ]

let () =
  Alcotest.run "runtime_account_removal"
    [ ( "remove"
      , [ Alcotest.test_case "the account and what routes to it go" `Quick
            test_the_account_and_what_routes_to_it_go
        ; Alcotest.test_case "an antigravity account takes its credentials table" `Quick
            test_an_antigravity_account_takes_its_credentials_table
        ; Alcotest.test_case "accounts using a shared model set are removed" `Quick
            test_accounts_using_a_shared_model_set_are_removed
        ; Alcotest.test_case "what has no replacement is refused" `Quick
            test_what_has_no_replacement_is_refused
        ; Alcotest.test_case "a lane named like its runtime keeps its routes" `Quick
            test_a_lane_named_like_its_runtime_keeps_its_routes
        ; Alcotest.test_case "a layout the line editor cannot reach is refused" `Quick
            test_a_layout_the_line_editor_cannot_reach_is_refused
        ; Alcotest.test_case "only an official-client account is removed" `Quick
            test_only_an_official_client_account_is_removed
        ] )
    ]
