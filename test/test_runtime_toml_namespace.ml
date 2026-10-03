(* #39539: a provider's bindings are a top-level table named after its id, so
   a provider may not be called by the name of a table another reader owns.
   Before, only eleven names were refused and [voice], [tui], [turn] or
   [fusion] loaded as a provider whose bindings sat in that reader's table. *)

module Ns = Runtime_toml_namespace

let provider_named name =
  Printf.sprintf
    {|[providers.%s]
display-name = "Named after a table"
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"
|}
    name

let refused_at path errors =
  List.exists (fun (e : Runtime_toml.parse_error) -> e.path = path) errors

(* [reserved_provider_ids] is the list the dashboard receives, so it must
   hold every table and be exactly what the loader refuses. *)
let test_no_provider_takes_a_table_another_reader_owns () =
  let names = Runtime_toml.reserved_provider_ids in
  List.iter
    (fun table ->
      Alcotest.(check bool) (Ns.key table ^ " is reserved") true
        (List.mem (Ns.key table) names))
    Ns.all;
  List.iter
    (fun owned ->
      Alcotest.(check bool) (owned ^ " is reserved") true (List.mem owned names))
    Keeper_runtime_config.owned_namespaces;
  Alcotest.(check bool) "the keeper settings' tables are among them" true
    (List.mem "turn" names && List.mem "keeper_settings" names);
  (* Each table has one owner, and the dashboard refuses a list that
     repeats a name. *)
  Alcotest.(check int) "no name is reserved twice" (List.length names)
    (List.length (List.sort_uniq String.compare names));
  List.iter
    (fun name ->
      match Runtime_toml.parse_string (provider_named name) with
      | Ok _ -> Alcotest.failf "a provider called %s was accepted" name
      | Error errors ->
        Alcotest.(check bool)
          (Printf.sprintf "%s is refused as a provider id" name)
          true
          (refused_at ("providers." ^ name) errors))
    names

(* Written out by hand. The loop above reads the same sources as the loader,
   so it would stay green if a table dropped out of the variant or the
   registry; these are the names #39539 found loading as providers. *)
let test_the_names_that_loaded_as_providers_are_refused () =
  List.iter
    (fun name ->
      match Runtime_toml.parse_string (provider_named name) with
      | Ok _ -> Alcotest.failf "a provider called %s was accepted" name
      | Error errors ->
        Alcotest.(check bool)
          (Printf.sprintf "%s is refused as a provider id" name)
          true
          (refused_at ("providers." ^ name) errors))
    [ "voice"; "fusion"; "tui"; "slack"; "discord"; "repositories"; "browser"
    ; "typesafeai"; "memory_os"; "keeper_settings"; "turn"; "wire_capture"
    ; "reactive"; "vision"; "board"
    ]

(* #39691 gives [board] to the moderator settings reader. This remains a
   reader-owned table even when a provider of the same name is declared. *)
let test_board_moderation_settings_cannot_be_a_provider_namespace () =
  let settings = {|[board]
moderators = ["board-moderator-fixture"]
|} in
  (match Runtime_toml.parse_string (provider_named "codex_second" ^ settings) with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "Board settings beside an ordinary provider were refused");
  match Runtime_toml.parse_string (provider_named "board" ^ settings) with
  | Ok _ -> Alcotest.fail "the Board moderator table was accepted as a provider namespace"
  | Error errors ->
      Alcotest.(check bool) "the provider declaration names the collision" true
        (refused_at "providers.board" errors)

(* The same declaration under a name nobody reads loads, so the refusals
   above are about the name. *)
let test_a_name_no_reader_owns_is_a_provider () =
  match Runtime_toml.parse_string (provider_named "codex_second") with
  | Ok _ -> ()
  | Error errors ->
    Alcotest.failf "a plain provider id was refused: %s"
      (String.concat "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

(* A model id sits under [models] and inside [<provider>.<model>], and an SSH
   endpoint under [exec.ssh.endpoints]; neither is a top-level table, so a
   table's name is theirs to use. [vision] is a keeper-settings namespace and
   a model id existing fixtures and scripts already declare. *)
let test_model_and_endpoint_ids_may_share_a_table_name () =
  let content =
    {|[models.vision]
api-name = "vision-model"
max-context = 1024

[models.turn]
api-name = "turn-model"
max-context = 1024

[exec.ssh.endpoints.sandbox]
host = "builder.local"
user = "masc-exec"
remote_root = "/srv/masc/playground"
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> ()
  | Error errors ->
    Alcotest.failf "model or endpoint ids named after a table were refused: %s"
      (String.concat "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

let test_each_table_has_one_spelling () =
  let keys = List.map Ns.key Ns.all in
  Alcotest.(check int) "no two tables share a spelling" (List.length keys)
    (List.length (List.sort_uniq String.compare keys));
  List.iter
    (fun table ->
      Alcotest.(check bool) (Ns.key table ^ " reads back") true
        (Ns.of_key (Ns.key table) = Some table))
    Ns.all;
  Alcotest.(check bool) "another name is no table" true (Ns.of_key "codex_second" = None);
  Alcotest.(check string) "a path under a table" "runtime.lanes" (Ns.(path Runtime) "lanes")

let shared_model = {|[models.sol]
api-name = "gpt-6.1-sol"
max-context = 272000
tools-support = true
streaming = true
reasoning-effort = "high"
|}

let shared_providers = {|[providers.first]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-first"
model-set = "codex"
[providers.second]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-second"
model-set = "codex"
|}

let parse_config text =
  match Runtime_toml.parse_string text with
  | Ok config -> config
  | Error errors -> Alcotest.failf "configuration refused: %s"
      (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) ->
         e.path ^ ": " ^ e.message) errors))

let test_one_model_serves_two_accounts () =
  let config = parse_config
    (shared_model ^ shared_providers ^ {|[model_sets.codex]
models = ["sol"]
[runtime]
default = "first.sol"
[runtime.assignments]
worker = "second.sol"
|}) in
  Alcotest.(check int) "the model is declared once" 1 (List.length config.models);
  Alcotest.(check (list string)) "both accounts share its model id"
    ["first.sol"; "second.sol"]
    (List.sort String.compare (List.map Runtime_schema.binding_key config.bindings));
  Alcotest.(check (list (option string))) "the account homes stay separate"
    [Some "/tmp/codex-first"; Some "/tmp/codex-second"]
    (List.map (fun (p : Runtime_schema.provider) -> p.account_home) config.providers);
  Alcotest.(check bool) "the shared declaration carries High" true
    ((List.hd config.models).reasoning_effort = Some Llm_provider.Reasoning_effort.High);
  Alcotest.(check (option string)) "assignment resolves the second binding"
    (Some "second.sol") (List.assoc_opt "worker" config.keeper_assignments)

let test_a_model_added_to_the_set_reaches_every_account () =
  let config = parse_config
    (shared_model ^ shared_providers ^ {|[models.next]
api-name = "future-sol"
max-context = 272000
[model_sets.codex]
models = ["sol", "next"]
|}) in
  Alcotest.(check (list string)) "one list addition generates both new bindings"
    ["first.next"; "first.sol"; "second.next"; "second.sol"]
    (List.sort String.compare (List.map Runtime_schema.binding_key config.bindings))

let test_generated_bindings_materialize_and_route () =
  let text = shared_providers ^ {|[models.sol]
api-name = "gpt-6-sol"
max-context = 272000
tools-support = true
streaming = true
reasoning-effort = "high"
[models.disabled]
api-name = "gpt-6-sol"
max-context = 272000
[model_sets.codex]
models = ["sol", "disabled"]
[first.disabled]
enabled = false
[second.disabled]
enabled = false
[runtime]
default = "first.sol"
[runtime.assignments]
worker = "second.sol"
|} in
  let path = Filename.temp_file "shared-model-runtime-" ".toml" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun channel -> output_string channel text);
    match Runtime.load_list ~config_path:path with
    | Error failure -> Alcotest.fail (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
    | Ok (runtimes, default, assignments, _, _) ->
      Alcotest.(check (list string)) "only the two enabled bindings materialize"
        ["first.sol"; "second.sol"]
        (List.sort String.compare (List.map (fun (r : Runtime_instance.t) -> r.id) runtimes));
      Alcotest.(check string) "generated default resolves" "first.sol" default.id;
      Alcotest.(check (option string)) "generated assignment resolves"
        (Some "second.sol") (List.assoc_opt "worker" assignments);
      List.iter (fun (id, expected_home) ->
        let runtime = List.find (fun (r : Runtime_instance.t) -> r.id = id) runtimes in
        match runtime.execution with
        | Runtime_execution.Codex_app_server client ->
          Alcotest.(check (option string)) (id ^ " account home")
            (Some expected_home) client.account_home
        | _ -> Alcotest.fail "generated binding changed execution protocol")
        [ "first.sol", "/tmp/codex-first"; "second.sol", "/tmp/codex-second" ])

let test_explicit_binding_overrides_a_set_default () =
  let config = parse_config
    (shared_model ^ shared_providers ^ {|[model_sets.codex]
models = ["sol"]
[second.sol]
enabled = false
max-concurrent = 2
|}) in
  Alcotest.(check int) "the override does not create a duplicate" 2
    (List.length config.bindings);
  let second = List.find (fun (b : Runtime_schema.binding) -> b.provider_id = "second")
      config.bindings in
  Alcotest.(check bool) "disable is preserved" false second.enabled;
  Alcotest.(check (option int)) "binding-only policy is preserved" (Some 2)
    second.max_concurrent

let test_invalid_model_sets_are_refused () =
  List.iter
    (fun (path, text) ->
       match Runtime_toml.parse_string text with
       | Ok _ -> Alcotest.failf "invalid set at %s was accepted" path
       | Error errors -> Alcotest.(check bool) path true (refused_at path errors))
    [ "providers.first.model-set", shared_model ^ shared_providers
    ; "providers.first.model-set", shared_model ^ {|[providers.first]
protocol = "codex-app-server"
command = "codex"
model-set = 1
|}
    ; "model_sets.codex.models", shared_model ^ {|[model_sets.codex]
models = ["missing"]
|}
    ; "model_sets.codex.models", shared_model ^ {|[model_sets.codex]
models = ["sol", "sol"]
|}
    ; "model_sets.codex.models", {|[model_sets.codex]
models = 1
|}
    ; "model_sets.codex.model", {|[model_sets.codex]
model = ["sol"]
|}
    ; "model_sets.codex", {|[model_sets]
codex = "sol"
|}
    ]

let model_set_provider key =
  Printf.sprintf {|[providers.first]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
%s = "codex"
|} key

let model_set_members = {|[model_sets.codex]
models = ["sol"]
|}

let test_model_set_typo_cannot_hide_behind_explicit_binding () =
  List.iter
    (fun explicit ->
      let text key =
        shared_model ^ model_set_provider key ^ model_set_members ^ explicit
      in
      let valid = parse_config (text "model-set") in
      Alcotest.(check (list string)) "canonical field generates one binding"
        ["first.sol"] (List.map Runtime_schema.binding_key valid.bindings);
      match Runtime_toml.parse_string (text "model_set") with
      | Ok _ -> Alcotest.fail "misspelled model set was silently ignored"
      | Error errors ->
        Alcotest.(check bool) "refusal identifies the original TOML path" true
          (refused_at "providers.first.model_set" errors))
    [ ""; "[first.sol]\nenabled = true\n[runtime]\ndefault = \"first.sol\"\n" ]

let test_unknown_provider_fields_are_refused_in_all_table_forms () =
  List.iter
    (fun (path, text) ->
      match Runtime_toml.parse_string text with
      | Ok _ -> Alcotest.failf "unknown provider field %s was accepted" path
      | Error errors -> Alcotest.(check bool) path true (refused_at path errors))
    [ "providers.first.model_set",
        "[providers]\nfirst = {protocol = \"codex-app-server\", command = \"codex\", model_set = \"codex\"}\n"
    ; "providers.first.model_set",
        "providers.first.protocol = \"codex-app-server\"\nproviders.first.command = \"codex\"\nproviders.first.model_set = \"codex\"\n"
    ; "providers.first.account_home",
        model_set_provider "model-set" ^ "account_home = \"/tmp/codex\"\n"
        ^ shared_model ^ model_set_members
    ; "providers.first.model_set",
        model_set_provider "model-set" ^ "[providers.first.model_set]\nname = \"codex\"\n"
        ^ shared_model ^ model_set_members
    ];
  match Runtime_toml.parse_string "[providers]\nfirst = 1\n" with
  | Ok _ -> Alcotest.fail "scalar provider accepted"
  | Error errors ->
    Alcotest.(check bool) "non-table provider is a structured error" true
      (refused_at "providers.first" errors)

let test_provider_typo_is_refused_by_file_loader () =
  let path = Filename.temp_file "provider-field-typo-" ".toml" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let content = shared_model ^ model_set_provider "model_set" ^ model_set_members
      ^ "[first.sol]\nenabled = true\n[runtime]\ndefault = \"first.sol\"\n" in
    Out_channel.with_open_bin path (fun channel -> output_string channel content);
    match Runtime.load_list ~config_path:path with
    | Ok _ -> Alcotest.fail "file loader silently dropped a misspelled model set"
    | Error failure ->
      let message = Runtime_config_error.to_diagnostic_text ~config_path:path failure in
      Alcotest.(check bool) "diagnostic includes the configuration file" true
        (String_util.contains_substring message path);
      Alcotest.(check bool) "diagnostic includes the misspelled field" true
        (String_util.contains_substring message "providers.first.model_set"))

let () =
  Alcotest.run "runtime_toml_namespace"
    [ ( "namespaces"
      , [ Alcotest.test_case "no provider takes a table another reader owns" `Quick
            test_no_provider_takes_a_table_another_reader_owns
        ; Alcotest.test_case "the names that loaded as providers are refused" `Quick
            test_the_names_that_loaded_as_providers_are_refused
        ; Alcotest.test_case "Board settings cannot be a provider namespace" `Quick
            test_board_moderation_settings_cannot_be_a_provider_namespace
        ; Alcotest.test_case "a name no reader owns is a provider" `Quick
            test_a_name_no_reader_owns_is_a_provider
        ; Alcotest.test_case "model and endpoint ids may share a table name" `Quick
            test_model_and_endpoint_ids_may_share_a_table_name
        ; Alcotest.test_case "each table has one spelling" `Quick
            test_each_table_has_one_spelling
        ; Alcotest.test_case "one shared model serves two accounts" `Quick
            test_one_model_serves_two_accounts
        ; Alcotest.test_case "a model list addition reaches every account" `Quick
            test_a_model_added_to_the_set_reaches_every_account
        ; Alcotest.test_case "generated bindings materialize and route" `Quick
            test_generated_bindings_materialize_and_route
        ; Alcotest.test_case "explicit binding overrides a set default" `Quick
            test_explicit_binding_overrides_a_set_default
        ; Alcotest.test_case "invalid model sets are refused" `Quick
            test_invalid_model_sets_are_refused
        ; Alcotest.test_case "model-set typo cannot hide behind explicit bindings" `Quick
            test_model_set_typo_cannot_hide_behind_explicit_binding
        ; Alcotest.test_case "unknown provider fields in all table forms" `Quick
            test_unknown_provider_fields_are_refused_in_all_table_forms
        ; Alcotest.test_case "provider typo is refused by the file loader" `Quick
            test_provider_typo_is_refused_by_file_loader
        ] )
    ]
