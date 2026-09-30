(* Adding a second sign-in of a client an operator already runs: the copy has
   to load, bind the base's models, and point the client at the new login
   store, without touching a line the operator already wrote. *)

module D = Runtime_account_declaration

let fixture =
  {|# operator note kept verbatim
[providers.claude_code]
display-name = "Claude Code Max"
protocol = "claude-code"
command = "/opt/masc/claude-subscription"
is-non-interactive = true

[providers.claude_bare]
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[providers.codex_subscription]
display-name = "Codex"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

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
path = "~/.gemini/antigravity-cli/antigravity-oauth-token"

[providers.muse]
display-name = "Muse"
protocol = "muse-serve"
command = "muse"
is-non-interactive = true

[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.sonnet]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[models.flash]
api-name = "gemini-3.7-flash-high"
max-context = 1000000
tools-support = true

[models.muse_fixture]
api-name = "muse-fixture-1"
max-context = 200000
max-prompt-bytes = 1048576
tools-support = true

[models.local-model]
api-name = "local"
max-context = 32000
tools-support = true

[claude_code.sonnet]
wizard-default = true

[codex_subscription."gpt-5.6"]
max-concurrent = 2
price-input = 0.075

[codex_acct1."gpt-5.6"]

[antigravity_subscription.flash]

[muse.muse_fixture]

[ollama.local-model]

[fusion]
|}

let home_dir = "/home/op"

(* The fixture's providers without account-home run on these. *)
let inherited_home = function
  | D.Codex -> Some "/home/op/.codex"
  | D.Claude_code -> Some "/home/op/.claude"
  | D.Muse -> Some "/home/op/.muse"
  | D.Antigravity -> None

let parsed text =
  match D.parse text with
  | Ok t -> t
  | Error e -> Alcotest.failf "fixture refused: %s" (D.error_message e)

let base_named t id =
  match List.find_opt (fun (b : D.base) -> b.id = id) (D.bases t) with
  | Some base -> base
  | None -> Alcotest.failf "no base %s" id

let declared ?(home_dir = home_dir) t ~base ~id ~location =
  match D.declare ~home_dir ~inherited_home t ~base:(base_named t base) ~id ~location with
  | Ok declared -> declared.D.text
  | Error e -> Alcotest.failf "declare %s refused: %s" id (D.error_message e)

let config_of text =
  match Runtime_toml.parse_string text with
  | Ok config -> config
  | Error _ -> Alcotest.fail "declared text does not load"

let bindings_of config provider =
  List.filter
    (fun (b : Runtime_schema.binding) -> b.provider_id = provider)
    config.Runtime_schema.bindings

let toml_of text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> Alcotest.failf "result is not TOML: %s" detail
  | Ok toml -> toml

let toml_string text path =
  Otoml.find_opt (toml_of text) (fun value -> Otoml.get_string value) path

let test_bases_are_the_signed_in_clients () =
  let t = parsed fixture in
  Alcotest.(check (list string)) "supported account-copy clients in file order, HTTP left out"
    [ "claude_code"; "claude_bare"; "codex_subscription"; "codex_acct1"
    ; "antigravity_subscription"; "muse" ]
    (List.map (fun (b : D.base) -> b.id) (D.bases t));
  Alcotest.(check string) "a provider without a name shows its id" "claude_bare"
    (base_named t "claude_bare").display_name;
  Alcotest.(check string) "the next free id after the base"
    "codex_subscription_2" (D.suggest_id t (base_named t "codex_subscription"))

let test_codex_copy_signs_in_at_the_new_home () =
  let t = parsed fixture in
  let text =
    declared t ~base:"codex_subscription" ~id:"codex_subscription_2"
      ~location:"~/.codex-account2"
  in
  Alcotest.(check bool) "every line the operator wrote is still there" true
    (String.starts_with ~prefix:fixture text);
  let config = config_of text in
  match bindings_of config "codex_subscription_2" with
  | [ binding ] ->
    Alcotest.(check string) "the base's model is bound" "gpt-5.6" binding.model_id;
    Alcotest.(check (option int)) "binding fields travel with it" (Some 2)
      binding.max_concurrent;
    (match Runtime_adapter.binding_to_execution config binding with
     | Ok (Runtime_execution.Codex_app_server execution) ->
       Alcotest.(check (option string)) "the turn runs in the new home"
         (Some "/home/op/.codex-account2") execution.account_home
     | Ok _ -> Alcotest.fail "the copy is no longer a Codex runtime"
     | Error detail -> Alcotest.failf "copy does not materialize: %s" detail)
  | bindings -> Alcotest.failf "expected one binding, got %d" (List.length bindings)

let test_claude_copy_keeps_the_command () =
  let t = parsed fixture in
  let text =
    declared t ~base:"claude_code" ~id:"claude_code_2"
      ~location:"/home/op/.claude-account2"
  in
  Alcotest.(check (option string)) "the wrapper the base runs is kept"
    (Some "/opt/masc/claude-subscription")
    (toml_string text [ "providers"; "claude_code_2"; "command" ]);
  Alcotest.(check (option string)) "the name says which account"
    (Some "Claude Code Max · claude_code_2")
    (toml_string text [ "providers"; "claude_code_2"; "display-name" ]);
  let config = config_of text in
  match bindings_of config "claude_code_2" with
  | [ binding ] ->
    Alcotest.(check bool) "wizard-default travels with it" true
      binding.wizard_default;
    (match Runtime_adapter.binding_to_execution config binding with
     | Ok (Runtime_execution.Claude_code execution) ->
       Alcotest.(check (option string)) "the turn runs in the new home"
         (Some "/home/op/.claude-account2") execution.account_home
     | Ok _ -> Alcotest.fail "the copy is no longer a Claude Code runtime"
     | Error detail -> Alcotest.failf "copy does not materialize: %s" detail)
  | bindings -> Alcotest.failf "expected one binding, got %d" (List.length bindings)

let test_muse_copy_signs_in_at_the_new_home () =
  let t = parsed fixture in
  let text =
    declared t ~base:"muse" ~id:"muse_2"
      ~location:"/home/op/.muse-account2"
  in
  Alcotest.(check bool) "every line the operator wrote is still there" true
    (String.starts_with ~prefix:fixture text);
  Alcotest.(check (option string)) "the new home is written as account-home"
    (Some "/home/op/.muse-account2")
    (toml_string text [ "providers"; "muse_2"; "account-home" ]);
  let config = config_of text in
  match bindings_of config "muse_2" with
  | [ binding ] ->
    Alcotest.(check string) "the base's model is bound" "muse_fixture" binding.model_id;
    (match Runtime_adapter.binding_to_execution config binding with
     | Ok (Runtime_execution.Muse_serve execution) ->
       Alcotest.(check string) "the turn runs in the new home"
         "/home/op/.muse-account2" execution.account_home
     | Ok _ -> Alcotest.fail "the copy is no longer a Muse runtime"
     | Error detail -> Alcotest.failf "copy does not materialize: %s" detail)
  | bindings -> Alcotest.failf "expected one binding, got %d" (List.length bindings)

let test_antigravity_copy_reads_the_new_oauth_file () =
  let t = parsed fixture in
  let text =
    declared t ~base:"antigravity_subscription" ~id:"agy_second"
      ~location:"/home/op/.masc/antigravity/second/oauth-token"
  in
  Alcotest.(check (option string)) "credentials point at the new file"
    (Some "/home/op/.masc/antigravity/second/oauth-token")
    (toml_string text [ "providers"; "agy_second"; "credentials"; "path" ]);
  Alcotest.(check (option string)) "no account-home on Antigravity" None
    (toml_string text [ "providers"; "agy_second"; "account-home" ]);
  let config = config_of text in
  Alcotest.(check (list string)) "the base's model is bound" [ "flash" ]
    (List.map (fun (b : Runtime_schema.binding) -> b.model_id)
       (bindings_of config "agy_second"))

let test_refusals () =
  let t = parsed fixture in
  let declare ?(home_dir = home_dir) base id location =
    D.declare ~home_dir ~inherited_home t ~base:(base_named t base) ~id ~location
  in
  (match declare "codex_subscription" "codex_acct1" "/home/op/.x" with
   | Error (D.Id_taken "codex_acct1") -> ()
   | _ -> Alcotest.fail "an existing provider id is refused");
  (match declare "codex_subscription" "fusion" "/home/op/.x" with
   | Error (D.Id_taken "fusion") -> ()
   | _ -> Alcotest.fail "a top-level table name is refused");
  (match declare "codex_subscription" "turn" "/home/op/.x" with
   | Error (D.Id_taken "turn") -> ()
   | _ -> Alcotest.fail "a name another reader owns is refused though the text lacks its table");
  (match declare "codex_subscription" "codex_3" "/home/op/.codex-account1" with
   | Error (D.Location_taken { provider = "codex_acct1"; _ }) -> ()
   | _ -> Alcotest.fail "a home another Codex provider signs in at is refused");
  (match
     declare "antigravity_subscription" "agy_3"
       "/home/op/.gemini/antigravity-cli/antigravity-oauth-token"
   with
   | Error (D.Location_taken { provider = "antigravity_subscription"; _ }) -> ()
   | _ -> Alcotest.fail "the base's ~/ OAuth file, written out, is refused");
  (match declare "codex_subscription" "codex_3" "/home/op/.codex-account1/" with
   | Error (D.Location_taken { provider = "codex_acct1"; _ }) -> ()
   | _ -> Alcotest.fail "the same home with a trailing slash is refused");
  (match declare "codex_subscription" "codex_3" "~/.codex" with
   | Error (D.Location_taken { provider = "codex_subscription"; _ }) -> ()
   | _ -> Alcotest.fail "the home a provider without account-home runs on is refused");
  (match
     D.declare ~inherited_home t ~base:(base_named t "codex_subscription") ~id:"codex_3"
       ~location:"~/.codex-3"
   with
   | Error (D.Invalid_location _) -> ()
   | _ -> Alcotest.fail "~/ without HOME is refused");
  (match declare "codex_subscription" "codex_3" "codex-home" with
   | Error (D.Invalid_location _) -> ()
   | _ -> Alcotest.fail "a relative home is refused");
  (match declare "claude_bare" "claude_3" "/home/op/.claude-3" with
   | Error (D.Nothing_to_bind "claude_bare") -> ()
   | _ -> Alcotest.fail "a base with no binding is refused");
  (match declare "codex_subscription" "bad.id" "/home/op/.codex-bad" with
   | Error (D.Rejected (_ :: _)) -> ()
   | _ -> Alcotest.fail "the loader's own id rule refuses a dotted id");
  match
    D.declare ~inherited_home t
      ~base:{ D.id = "ollama"; display_name = "Local Ollama"; client = D.Codex; command = None }
      ~id:"ollama_2" ~location:"/home/op/.o"
  with
  | Error (D.Unknown_base "ollama") -> ()
  | _ -> Alcotest.fail "an HTTP provider is not a base"

(* Otoml's own printer writes floats to two places. A copied price or timeout
   has to arrive as the base wrote it, and a whole-number float has to stay a
   float. *)
let test_copied_numbers_keep_their_value () =
  let t = parsed fixture in
  let codex =
    toml_of (declared t ~base:"codex_subscription" ~id:"codex_2" ~location:"/home/op/.c2")
  in
  Alcotest.(check (option (float 0.))) "price-input is copied exactly" (Some 0.075)
    (Otoml.find_opt codex (fun v -> Otoml.get_float ~strict:true v)
       [ "codex_2"; "gpt-5.6"; "price-input" ]);
  let agy =
    toml_of
      (declared t ~base:"antigravity_subscription" ~id:"agy_2" ~location:"/home/op/.a2")
  in
  Alcotest.(check (option (float 0.))) "timeout-s stays the float 180.0" (Some 180.0)
    (Otoml.find_opt agy (fun v -> Otoml.get_float ~strict:true v)
       [ "providers"; "agy_2"; "timeout-s" ])

let test_shared_model_set_account_copy () =
  let source =
    {|[providers.codex]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
model-set = "codex_models"

[models.sol]
api-name = "gpt-6.1-sol"
max-context = 272000

[models.astra]
api-name = "gpt-6-astra"
max-context = 272000

[model_sets.codex_models]
models = ["sol", "astra"]
|}
  in
  let check_models text =
    Alcotest.(check (list string)) "both accounts resolve the shared models"
      [ "astra"; "sol" ]
      (List.sort String.compare
         (List.map (fun (b : Runtime_schema.binding) -> b.model_id)
            (bindings_of (config_of text) "codex_2")));
    Alcotest.(check (option string)) "the new account keeps the set reference"
      (Some "codex_models") (toml_string text [ "providers"; "codex_2"; "model-set" ])
  in
  let generated =
    declared (parsed source) ~base:"codex" ~id:"codex_2" ~location:"/home/op/.codex-new"
  in
  check_models generated;
  Alcotest.(check bool) "generated bindings stay generated" false
    (Otoml.find_opt (toml_of generated) Fun.id [ "codex_2" ] <> None);
  Alcotest.(check bool) "a generated binding has no wizard-default override" true
    (List.for_all (fun (b : Runtime_schema.binding) -> not b.wizard_default)
       (bindings_of (config_of generated) "codex_2"));
  let overridden =
    declared
      (parsed (source ^ "\n[codex.sol]\nenabled = false\nmax-concurrent = 3\nwizard-default = true\n"))
      ~base:"codex" ~id:"codex_2" ~location:"/home/op/.codex-new"
  in
  check_models overridden;
  let overrides =
    List.find (fun (b : Runtime_schema.binding) -> String.equal b.model_id "sol")
      (bindings_of (config_of overridden) "codex_2")
  in
  Alcotest.(check bool) "explicit disabled state travels with the account" false overrides.enabled;
  Alcotest.(check (option int)) "explicit concurrency travels with the account" (Some 3)
    overrides.max_concurrent;
  Alcotest.(check bool) "explicit wizard default travels with the account" true
    overrides.wizard_default;
  Alcotest.(check bool) "generated models do not become explicit overrides" false
    (Otoml.find_opt (toml_of overridden) Fun.id [ "codex_2"; "astra" ] <> None)

(* Layouts the append cannot carry. A [[table array]] under the base is
   printed after the copy's own keys, not over them; a providers table
   written inline cannot take a section after it, so that is refused rather
   than written as TOML another reader rejects. *)
let test_layouts_the_append_cannot_carry () =
  let with_notes =
    parsed
      {|[providers.cc]
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[[providers.cc.notes]]
text = "first"

[models.sonnet]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true

[cc.sonnet]
|}
  in
  Alcotest.(check (option string)) "account-home is not swallowed by the table array"
    (Some "/home/op/.cc2")
    (toml_string (declared with_notes ~base:"cc" ~id:"cc_2" ~location:"/home/op/.cc2")
       [ "providers"; "cc_2"; "account-home" ]);
  let inline =
    parsed
      {|providers = { cc = { protocol = "claude-code", command = "claude", is-non-interactive = true } }

[models.sonnet]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true

[cc.sonnet]
|}
  in
  match
    D.declare ~inherited_home inline ~base:(base_named inline "cc") ~id:"cc_2"
      ~location:"/home/op/.cc2"
  with
  | Error (D.Unsupported_layout _) -> ()
  | _ -> Alcotest.fail "an inline providers table is refused"

(* The shipped seed is what a first account is copied from on a fresh
   install. Every client it declares has to take a second account. *)
let test_every_seed_client_takes_a_second_account () =
  let seed =
    match Sys.getenv_opt "MASC_TEST_RUNTIME_SEED" with
    | Some path -> In_channel.with_open_bin path In_channel.input_all
    | None -> Alcotest.fail "MASC_TEST_RUNTIME_SEED is not set"
  in
  let t = parsed seed in
  let shared_models =
    Otoml.find (toml_of seed) (Otoml.get_array Otoml.get_string)
      [ "model_sets"; "codex"; "models" ]
    |> List.sort String.compare
  in
  let configured_codex_models =
    bindings_of (config_of seed) "codex_subscription"
    |> List.map (fun (binding : Runtime_schema.binding) -> binding.model_id)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "a new account's shared list includes every shipped Codex profile"
    configured_codex_models shared_models;
  let bases = D.bases t in
  Alcotest.(check bool) "the seed declares official clients" true (bases <> []);
  List.iter
    (fun (base : D.base) ->
      let id = D.suggest_id t base in
      match
        D.declare ~home_dir ~inherited_home t ~base ~id
          ~location:("/home/op/.accounts/" ^ id)
      with
      | Ok declared ->
        Alcotest.(check bool) (id ^ " binds models") true
          (bindings_of (config_of declared.D.text) id <> [])
      | Error e -> Alcotest.failf "%s refused: %s" id (D.error_message e))
    bases

(* A login store is the directory the client opens, however it is spelled.
   The review case (#39518): the base signs in at [accounts/../shared] and the
   copy is offered [shared], which is the same directory. *)
let test_one_directory_by_any_spelling () =
  let root = Filename.temp_dir "masc-account-declaration" "" in
  let path part = Filename.concat root part in
  Sys.mkdir (path "accounts") 0o755;
  Sys.mkdir (path "real") 0o755;
  Unix.symlink (path "real") (path "link");
  let text =
    Printf.sprintf
      {|[providers.codex_subscription]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "%s"

[providers.codex_linked]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "%s"

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000

[codex_subscription."gpt-5.6"]

[codex_linked."gpt-5.6"]
|}
      (path "accounts/../shared")
      (path "real")
  in
  let t = parsed text in
  let declare location =
    D.declare ~inherited_home t ~base:(base_named t "codex_subscription") ~id:"codex_3"
      ~location
  in
  let taken_by location =
    match declare location with
    | Error (D.Location_taken { provider; _ }) -> Some provider
    | Ok _ -> None
    | Error e -> Alcotest.failf "%s: %s" location (D.error_message e)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote root)))
    (fun () ->
      Alcotest.(check (option string)) "[..] in the base's home"
        (Some "codex_subscription") (taken_by (path "shared"));
      Alcotest.(check (option string)) "[..] in the offered home"
        (Some "codex_linked") (taken_by (path "accounts/../real"));
      Alcotest.(check (option string)) "a link to a home"
        (Some "codex_linked") (taken_by (path "link"));
      Alcotest.(check (option string)) "another directory" None
        (taken_by (path "elsewhere"));
      (* Only a case-insensitive disk makes [REAL] the same directory. *)
      let case_insensitive = Sys.file_exists (path "REAL") in
      Alcotest.(check (option string)) "letter case, as the disk reads it"
        (if case_insensitive then Some "codex_linked" else None)
        (taken_by (path "REAL")))
;;

let with_temp_dir f =
  let root = Filename.temp_dir "masc-account-declaration" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote root)))
    (fun () -> f (Filename.concat root))

(* The provider [declare] names when it refuses [location] as a login already
   in use; [None] when the copy is declared. *)
let signed_in_by t ~base location =
  match D.declare ~inherited_home t ~base:(base_named t base) ~id:"copy" ~location with
  | Error (D.Location_taken { provider; _ }) -> Ok (Some provider)
  | Ok _ -> Ok None
  | Error e -> Error e

let check_signed_in label expected actual =
  Alcotest.(check (result (option string) string))
    label expected (Result.map_error D.error_message actual)

(* A home is often declared before the client first signs in, so it does not
   exist yet. It still has to be compared with where a client will open it
   once it does: through a link that points at it already, and in the letter
   case a case-insensitive disk would ignore. *)
let test_a_home_that_does_not_exist_yet () =
  with_temp_dir (fun path ->
    Sys.mkdir (path "accounts") 0o755;
    Unix.symlink (path "accounts/new-home") (path "accounts/alias");
    Unix.symlink "waiting" (path "accounts/relative-alias");
    Unix.symlink (path "loop") (path "loop");
    Out_channel.with_open_bin (path "regular-file") (fun out ->
      Out_channel.output_string out "not a directory");
    let t =
      parsed
        (Printf.sprintf
           {|[providers.codex_subscription]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "%s"

[providers.codex_waiting]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "%s"

[providers.codex_lower]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "%s"

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000

[codex_subscription."gpt-5.6"]

[codex_waiting."gpt-5.6"]

[codex_lower."gpt-5.6"]
|}
           (path "accounts/alias")
           (path "accounts/waiting")
           (path "accounts/acct-new"))
    in
    let taken_by = signed_in_by t ~base:"codex_subscription" in
    check_signed_in "the home a provider's link will lead to"
      (Ok (Some "codex_subscription")) (taken_by (path "accounts/new-home"));
    check_signed_in "a relative link to a home a provider will create"
      (Ok (Some "codex_waiting")) (taken_by (path "accounts/relative-alias"));
    check_signed_in "letter case of a name that does not exist yet"
      (Ok (Some "codex_lower")) (taken_by (path "accounts/ACCT-NEW"));
    check_signed_in "another name that does not exist yet" (Ok None)
      (taken_by (path "accounts/other"));
    (match taken_by (path "regular-file/child") with
     | Error (D.Invalid_location _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "a home below a file is refused");
    match taken_by (path "loop") with
    | Error (D.Invalid_location _) -> ()
    | Ok _ | Error _ -> Alcotest.fail "a link that leads to itself is refused")

(* Antigravity signs in with a file, and a file has as many names as it has
   hard links. *)
let test_an_oauth_file_by_any_name () =
  with_temp_dir (fun path ->
    let write name =
      Out_channel.with_open_bin (path name) (fun out ->
        Out_channel.output_string out "token")
    in
    write "oauth-a";
    write "oauth-copy";
    Unix.link (path "oauth-a") (path "oauth-b");
    Unix.symlink (path "oauth-a") (path "oauth-link");
    let t =
      parsed
        (Printf.sprintf
           {|[providers.agy]
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 180.0

[providers.agy.credentials]
type = "file"
path = "%s"

[models.flash]
api-name = "gemini-3.7-flash-high"
max-context = 1000000

[agy.flash]
|}
           (path "oauth-a"))
    in
    let taken_by = signed_in_by t ~base:"agy" in
    check_signed_in "a hard link to the file" (Ok (Some "agy"))
      (taken_by (path "oauth-b"));
    check_signed_in "a link to the file" (Ok (Some "agy"))
      (taken_by (path "oauth-link"));
    check_signed_in "another file with the same bytes" (Ok None)
      (taken_by (path "oauth-copy")))

let () =
  Alcotest.run "runtime_account_declaration"
    [ ( "declare"
      , [ Alcotest.test_case "bases are the signed-in clients" `Quick
            test_bases_are_the_signed_in_clients
        ; Alcotest.test_case "codex copy signs in at the new home" `Quick
            test_codex_copy_signs_in_at_the_new_home
        ; Alcotest.test_case "claude copy keeps the command" `Quick
            test_claude_copy_keeps_the_command
        ; Alcotest.test_case "muse copy signs in at the new home" `Quick
            test_muse_copy_signs_in_at_the_new_home
        ; Alcotest.test_case "antigravity copy reads the new oauth file" `Quick
            test_antigravity_copy_reads_the_new_oauth_file
        ; Alcotest.test_case "refusals" `Quick test_refusals
        ; Alcotest.test_case "one directory by any spelling" `Quick
            test_one_directory_by_any_spelling
        ; Alcotest.test_case "a home that does not exist yet" `Quick
            test_a_home_that_does_not_exist_yet
        ; Alcotest.test_case "an oauth file by any name" `Quick
            test_an_oauth_file_by_any_name
        ; Alcotest.test_case "copied numbers keep their value" `Quick
            test_copied_numbers_keep_their_value
        ; Alcotest.test_case "shared model set account copy" `Quick
            test_shared_model_set_account_copy
        ; Alcotest.test_case "layouts the append cannot carry" `Quick
            test_layouts_the_append_cannot_carry
        ; Alcotest.test_case "every seed client takes a second account" `Quick
            test_every_seed_client_takes_a_second_account
        ] )
    ]
