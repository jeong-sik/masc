(* RFC account-provider-speaks-as-a-catalog-row: two Anthropic accounts, each
   its own [providers.<id>] with its own key, name the catalog row [claude]
   with [catalog-provider]. The catalog answers for both; the accounts stay
   apart in admission and quota. *)

open Alcotest
open Masc

module Registry = Runtime_exact_output_registry

let require_ok label = function Ok value -> value | Error _ -> fail label
let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.equal (String.sub haystack i n) needle || at (i + 1)) in
  at 0
;;
let lane_id = "librarian_exact"
let key_a = "MASC_TEST_CLAUDE_A_KEY"
let key_b = "MASC_TEST_CLAUDE_B_KEY"
let slot_a = "claude_a.haiku"
let slot_b = "claude_b.haiku"

let account ?(extra = "") ?seats name key =
  Printf.sprintf {|[providers.%s]
protocol = "messages-http"
endpoint = "https://api.anthropic.com"
exact-body-timeout-s = 1200.0
%s
[providers.%s.credentials]
type = "env"
key = "%s"

[%s.haiku]
%s
|}
    name
    extra
    name
    key
    name
    (match seats with None -> "" | Some seats -> Printf.sprintf "max-concurrent = %d" seats)
;;

let runtime_toml ?(a = account "claude_a" key_a ~extra:"catalog-provider = \"claude\"")
    ?(b = account "claude_b" key_b ~extra:"catalog-provider = \"claude\"") () =
  String.concat "\n"
    ([ Printf.sprintf "[runtime]\ndefault = %S\n" slot_b
     ; "[models.haiku]\napi-name = \"claude-haiku-5-5\"\n"
     ; a
     ; b
     ]
     @ List.map
         (fun lane ->
            Printf.sprintf
              "[runtime.exact_output_lanes.%s]\nslots = [%S, %S]\nmax_output_tokens = 4096\n"
              lane slot_a slot_b)
         (List.sort_uniq String.compare (lane_id :: Standalone_lane.required_ids)))
;;

let with_fixture f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env key_a (Some "synthetic-no-network-a") @@ fun () ->
  Masc_test_deps.with_process_env key_b (Some "synthetic-no-network-b") @@ fun () ->
  let root = Filename.temp_dir "account-catalog-row-" "" in
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some root) @@ fun () ->
  Config_dir_resolver.reset ();
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Runtime.unpublish_exact_output_registry () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    Llm_provider.Catalog_snapshot.publish previous_catalog;
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Catalog_snapshot.reset ();
  let path = Filename.concat root "runtime.toml" in
  f ~root ~path
;;

let boot ~root ~path text =
  Fs_compat.save_file path text;
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> failf "runtime initialization: %s" detail);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ()
;;

let load ~path text =
  Fs_compat.save_file path text;
  Runtime.load_list ~config_path:path
;;

let selected_slots registry lane =
  match Registry.resolve_lane registry ~lane_id:lane with
  | Ok { selected_slots; _ } ->
    List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) selected_slots
  | Error _ -> failf "lane %s must resolve" lane
;;

(* Without the key the same two accounts are dropped from every Exact lane at
   boot; with it both are slots, in the declared order, and nothing is
   rejected. *)
let test_accounts_of_a_catalog_row_are_exact_slots () =
  with_fixture @@ fun ~root ~path ->
  boot ~root ~path (runtime_toml ());
  let registry = Registry.current () |> require_ok "published registry" in
  check (list string) "both accounts are slots of the lane" [ slot_a; slot_b ]
    (selected_slots registry lane_id);
  check (list string) "no slot is rejected" []
    (List.map (fun (slot : Registry.rejected_slot) -> slot.slot_id)
       (Registry.rejected_slots registry))
;;

let test_accounts_without_the_key_are_not_exact_slots () =
  with_fixture @@ fun ~root ~path ->
  let manual name key = account name key ~extra:"kind = \"anthropic\"\nrequest-path = \"/v1/messages\"" in
  let text = runtime_toml ~a:(manual "claude_a" key_a) ~b:(manual "claude_b" key_b) () in
  (* What an operator writes today for an account the catalog does not know:
     the context window and a capabilities table, or boot drops the runtime. *)
  let with_capabilities =
    Str.global_replace (Str.regexp_string "api-name = \"claude-haiku-5-5\"\n")
      "api-name = \"claude-haiku-5-5\"\nmax-context = 200000\n" text
    ^ "\n[models.haiku.capabilities]\nsupports-system-prompt = true\n"
  in
  (* The runtimes load, so Keeper turns can use them, but the catalog has no
     row for either account: every lane is left with no slot and the required
     lanes refuse the registry. *)
  match boot ~root ~path with_capabilities with
  | () -> fail "the registry published with no slot the catalog can admit"
  | exception Env_config_core.Config_error message ->
    check bool "the runtimes loaded" true
      (Option.is_some (Runtime.get_runtime_by_id slot_a)
       && Option.is_some (Runtime.get_runtime_by_id slot_b));
    check bool "a required lane has no admitted slot" true
      (contains message "has no admitted target")
;;

(* Admission keeps one allowance per account. Two bindings of one account that
   declare different seats are refused; the same seats on two accounts of one
   catalog row are not, because each account has its own key. *)
let test_two_accounts_of_one_row_admit_apart () =
  with_fixture @@ fun ~root:_ ~path ->
  let text =
    runtime_toml
      ~a:(account "claude_a" key_a ~seats:2 ~extra:"catalog-provider = \"claude\"")
      ~b:(account "claude_b" key_b ~seats:3 ~extra:"catalog-provider = \"claude\"")
      ()
  in
  (match load ~path text with
   | Ok _ -> ()
   | Error failure ->
     failf "two accounts with their own seats must load: %s"
       (Runtime_config_error.to_diagnostic_text ~config_path:path failure));
  let one_account_two_seats =
    text ^ "\n[models.sonnet]\napi-name = \"claude-sonnet-5-5\"\n\n[claude_a.sonnet]\nmax-concurrent = 3\n"
  in
  match load ~path one_account_two_seats with
  | Error (Runtime_config_error.Admission_allowances_disagree _) -> ()
  | Error failure ->
    failf "refused for another reason: %s"
      (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
  | Ok _ -> fail "one account declaring two seat counts must be refused"
;;

let test_a_spent_account_leaves_the_other_open () =
  with_fixture @@ fun ~root ~path ->
  boot ~root ~path (runtime_toml ());
  let scope id =
    match Runtime.get_runtime_by_id id with
    | Some runtime -> runtime.Runtime_instance.quota_scope
    | None -> failf "runtime %s must load" id
  in
  let now = Unix.gettimeofday () in
  Runtime_quota_window.note_exhausted ~scope:(scope slot_a)
    ~source:Runtime_quota_window.Payment_refused ~resets_at:(now +. 3600.0);
  check bool "the spent account rests" true
    (Runtime_quota_window.is_exhausted ~scope:(scope slot_a) ~now);
  check bool "the other account of the same row does not" false
    (Runtime_quota_window.is_exhausted ~scope:(scope slot_b) ~now)
;;

let refused_binding ~path text =
  match load ~path text with
  | Error (Runtime_config_error.Undeclared_bindings dropped) -> dropped
  | Error failure ->
    failf "refused for another reason: %s"
      (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
  | Ok _ -> fail "the configuration loaded"
;;

let test_a_catalog_provider_typo_is_refused_at_load () =
  with_fixture @@ fun ~root:_ ~path ->
  let text = runtime_toml ~a:(account "claude_a" key_a ~extra:"catalog-provider = \"claud\"") () in
  match refused_binding ~path text with
  | [ (id, Runtime_config_error.Catalog_provider_not_declared { provider_id; catalog_provider }) ] ->
    check string "the binding" slot_a id;
    check string "the account" "claude_a" provider_id;
    check string "the row it named" "claud" catalog_provider
  | dropped ->
    failf "unexpected refusal: %s"
      (String.concat "; "
         (List.map (fun (id, reason) -> id ^ ": " ^ Runtime_config_error.string_of_drop_reason reason) dropped))
;;

let test_a_catalog_row_that_names_another_row_is_refused () =
  with_fixture @@ fun ~root:_ ~path ->
  let text =
    runtime_toml ~a:(account "claude_a" key_a ~extra:"catalog-provider = \"claude\"")
      ~b:(account "claude_b" key_b ~extra:"catalog-provider = \"claude\"") ()
    ^ "\n" ^ account "claude" key_a ~extra:"catalog-provider = \"deepseek-anthropic\""
  in
  match refused_binding ~path text with
  | [ ("claude.haiku", Runtime_config_error.Catalog_provider_beside_own_row { provider_id = "claude"; _ }) ] -> ()
  | dropped ->
    failf "unexpected refusal: %s"
      (String.concat "; "
         (List.map (fun (id, reason) -> id ^ ": " ^ Runtime_config_error.string_of_drop_reason reason) dropped))
;;

(* The catalog owns the dialect of the row the account speaks as, exactly as
   it does for a provider whose id is that row: a stated [kind] drops the
   binding instead of being read. *)
let test_kind_beside_catalog_provider_drops_the_binding () =
  with_fixture @@ fun ~root:_ ~path ->
  let text =
    runtime_toml
      ~a:(account "claude_a" key_a ~extra:"catalog-provider = \"claude\"\nkind = \"anthropic\"") ()
  in
  match load ~path text with
  | Ok (runtimes, _, _, _, _) ->
    check bool "the account with a stated kind is not a runtime" false
      (List.exists (fun (runtime : Runtime_instance.t) -> String.equal runtime.id slot_a) runtimes);
    check bool "the other account is" true
      (List.exists (fun (runtime : Runtime_instance.t) -> String.equal runtime.id slot_b) runtimes)
  | Error failure ->
    failf "a dropped binding is not a load failure: %s"
      (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
;;

let test_an_official_client_may_not_name_a_catalog_row () =
  let text = {|[providers.cli]
protocol = "claude-code"
command = "claude"
is-non-interactive = true
catalog-provider = "claude"
|} in
  match Runtime_toml.parse_string text with
  | Ok _ -> fail "an official client naming a catalog row must not parse"
  | Error errors ->
    check bool "the error names the key" true
      (List.exists
         (fun (error : Runtime_toml.parse_error) -> String.equal error.path "providers.cli.catalog-provider")
         errors)
;;

let () =
  run "account provider catalog row"
    [ ( "exact"
      , [ test_case "accounts of a catalog row are exact slots" `Quick
            test_accounts_of_a_catalog_row_are_exact_slots
        ; test_case "accounts without the key are not exact slots" `Quick
            test_accounts_without_the_key_are_not_exact_slots
        ] )
    ; ( "accounts"
      , [ test_case "two accounts of one row admit apart" `Quick
            test_two_accounts_of_one_row_admit_apart
        ; test_case "a spent account leaves the other open" `Quick
            test_a_spent_account_leaves_the_other_open
        ] )
    ; ( "refusals"
      , [ test_case "a catalog-provider typo is refused at load" `Quick
            test_a_catalog_provider_typo_is_refused_at_load
        ; test_case "a catalog row that names another row is refused" `Quick
            test_a_catalog_row_that_names_another_row_is_refused
        ; test_case "kind beside catalog-provider drops the binding" `Quick
            test_kind_beside_catalog_provider_drops_the_binding
        ; test_case "an official client may not name a catalog row" `Quick
            test_an_official_client_may_not_name_a_catalog_row
        ] )
    ]
;;
