(* The setup API's account removal: the preview names the changes and the
   revision it read, and the removal commits them only while runtime.toml is
   still that revision. Every refusal is checked against the bytes on disk. *)

open Alcotest
module S = Runtime_account_removal_setup

let fixture =
  {|# operator note above everything
[runtime]
default = "stub-http.stub-model"

[runtime.lanes.coding]
candidates = ["codex_acct1.gpt-5.6", "stub-http.stub-model"]

[runtime.assignments]
sangsu = "codex_acct1.gpt-5.6"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.codex_subscription]
display-name = "Codex"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

[providers.codex_acct1]
display-name = "Codex one"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-one"

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[stub-http.stub-model]

[codex_subscription."gpt-5.6"]

[codex_acct1."gpt-5.6"]
|}
;;

(* A commit refuses a model the AGENT_CORE catalog does not know, so the
   stub's model is declared to it, as test_fusion_config_edit does. *)
let model_catalog =
  {|
[[models]]
id_prefix = "gpt-5.4"
provider_name = "stub-http"
base = "openai_chat"
max_context_tokens = 200000
supports_tools = true
|}
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let contains ~sub text =
  match Str.search_forward (Str.regexp_string sub) text 0 with
  | _ -> true
  | exception Not_found -> false
;;
let write_file path content = Out_channel.with_open_bin path (fun oc -> output_string oc content)

let with_config f =
  let previous = Llm_provider.Model_catalog.global () in
  let catalog_path = Filename.temp_file "account-removal-setup-models" ".toml" in
  let snapshot = Runtime.For_testing.snapshot () in
  let dir = Filename.temp_dir "account-removal-setup" "" in
  let path = Filename.concat dir "runtime.toml" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      (match previous with
       | Some catalog -> Llm_provider.Model_catalog.set_global catalog
       | None -> Llm_provider.Model_catalog.clear_global ());
      try Sys.remove catalog_path with
      | Sys_error _ -> ())
    (fun () ->
       write_file catalog_path model_catalog;
       (match Llm_provider.Model_catalog.load_file catalog_path with
        | Error detail -> failf "the test model catalog must load: %s" detail
        | Ok catalog -> Llm_provider.Model_catalog.set_global catalog);
       write_file path fixture;
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "the fixture runtime must initialize: %s" detail
       | Ok () -> f path)
;;

let field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_at key json =
  match field key json with
  | Some (`String value) -> value
  | _ -> failf "no string %s in %s" key (Yojson.Safe.to_string json)
;;

let preview path id =
  match S.preview ~runtime_config_path:path (`Assoc [ "integration_id", `String id ]) with
  | Ok json -> json
  | Error e -> failf "the preview failed: %s" (S.error_message e)
;;

let remove path id revision =
  S.remove ~runtime_config_path:path
    (`Assoc [ "integration_id", `String id; "revision", `String revision ])
;;

let test_the_preview_names_what_the_removal_changes () =
  with_config (fun path ->
    let json = preview path "codex_acct1" in
    check string "removable" "removable" (string_at "state" json);
    check string "the login store stays on disk" "/tmp/codex-one" (string_at "login_store" json);
    let changes =
      match field "changes" json with
      | Some (`List changes) -> List.map Yojson.Safe.to_string changes
      | _ -> fail "no changes"
    in
    List.iter
      (fun change -> check bool ("lists " ^ change) true (List.mem change changes))
      [ {|{"kind":"table","path":"providers.codex_acct1"}|}
      ; {|{"kind":"table","path":"codex_acct1.\"gpt-5.6\""}|}
      ; {|{"kind":"lane_candidate","lane":"coding","runtime":"codex_acct1.gpt-5.6"}|}
      ; {|{"kind":"assignment","keeper":"sangsu","runtime":"codex_acct1.gpt-5.6"}|}
      ];
    check string "the file is untouched" fixture (read path))
;;

let test_a_refused_removal_is_a_preview_not_an_error () =
  with_config (fun path ->
    let json = preview path "stub-http" in
    check string "refused" "refused" (string_at "state" json);
    check bool "with the reason" true (String.length (string_at "reason" json) > 0))
;;

let test_the_removal_commits_what_the_preview_listed () =
  with_config (fun path ->
    let revision = string_at "revision" (preview path "codex_acct1") in
    match remove path "codex_acct1" revision with
    | Error e -> failf "the removal failed: %s" (S.error_message e)
    | Ok _ ->
      let text = read path in
      List.iter
        (fun gone -> check bool ("gone: " ^ gone) false (contains ~sub:gone text))
        [ "[providers.codex_acct1]"; "sangsu = "; "\"codex_acct1.gpt-5.6\"" ];
      List.iter
        (fun kept -> check bool ("kept: " ^ kept) true (contains ~sub:kept text))
        [ "# operator note above everything"; "[providers.codex_subscription]" ])
;;

let test_a_file_changed_since_the_preview_is_left_alone () =
  with_config (fun path ->
    let revision = string_at "revision" (preview path "codex_acct1") in
    let changed = read path ^ "\n# written by someone else\n" in
    write_file path changed;
    (match remove path "codex_acct1" revision with
     | Error S.Configuration_changed -> ()
     | Error e -> failf "the wrong refusal: %s" (S.error_message e)
     | Ok _ -> fail "a removal from a file the preview never read was committed");
    check string "the file is untouched" changed (read path))
;;

let test_a_refused_account_is_not_removed () =
  with_config (fun path ->
    let revision = string_at "revision" (preview path "stub-http") in
    (match remove path "stub-http" revision with
     | Error (S.Refused _) -> ()
     | Error e -> failf "the wrong refusal: %s" (S.error_message e)
     | Ok _ -> fail "an HTTP provider was removed as an account");
    check string "the file is untouched" fixture (read path))
;;

let test_a_body_with_other_fields_is_refused () =
  with_config (fun path ->
    List.iter
      (fun body ->
        match S.remove ~runtime_config_path:path body with
        | Error S.Invalid_request -> ()
        | Error e -> failf "the wrong refusal: %s" (S.error_message e)
        | Ok _ -> fail "a malformed body was committed")
      [ `Assoc [ "integration_id", `String "codex_acct1" ]
      ; `Assoc [ "integration_id", `String "codex_acct1"; "revision", `String "r"; "extra", `Bool true ]
      ; `Assoc [ "integration_id", `String " codex_acct1"; "revision", `String "r" ]
      ; `List []
      ];
    check string "the file is untouched" fixture (read path))
;;

let () =
  run "runtime_account_removal_setup"
    [ ( "setup"
      , [ test_case "the preview names what the removal changes" `Quick
            test_the_preview_names_what_the_removal_changes
        ; test_case "a refused removal is a preview, not an error" `Quick
            test_a_refused_removal_is_a_preview_not_an_error
        ; test_case "the removal commits what the preview listed" `Quick
            test_the_removal_commits_what_the_preview_listed
        ; test_case "a file changed since the preview is left alone" `Quick
            test_a_file_changed_since_the_preview_is_left_alone
        ; test_case "a refused account is not removed" `Quick
            test_a_refused_account_is_not_removed
        ; test_case "a body with other fields is refused" `Quick
            test_a_body_with_other_fields_is_refused
        ] )
    ]
;;
