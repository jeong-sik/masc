(* The runtime.toml pane's account form, driven the way the key loop drives
   it: one decoded key at a time. *)

module F = Masc_tui_runtime_account_form

let fixture =
  {|[providers.codex_subscription]
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

[providers.claude_code]
display-name = "Claude Code\u001b[31m red"
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[models.sonnet]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true

[codex_subscription."gpt-5.6"]
[codex_acct1."gpt-5.6"]
[claude_code.sonnet]
|}

let opened () =
  match F.open_on ~home_dir:"/home/op" fixture with
  | Ok form -> form
  | Error reason -> Alcotest.failf "the form did not open: %s" reason

let typed text = List.init (String.length text) (fun i -> String.make 1 text.[i])

(* The fixture's codex_subscription has no account-home and runs on this. *)
let inherited_home = function
  | Runtime_account_declaration.Codex -> Some "/home/op/.codex"
  | Runtime_account_declaration.Claude_code
  | Runtime_account_declaration.Antigravity
  | Runtime_account_declaration.Muse -> None

let press form keys =
  List.fold_left
    (fun outcome key ->
      match outcome with
      | F.Editing form -> F.key form key
      | F.Cancelled | F.Submitted _ -> outcome)
    (F.Editing form) keys

let editing = function
  | F.Editing form -> form
  | F.Cancelled -> Alcotest.fail "the form closed"
  | F.Submitted _ -> Alcotest.fail "the form submitted"

let submitted = function
  | F.Submitted form -> form
  | F.Editing _ -> Alcotest.fail "enter on the last field did not submit"
  | F.Cancelled -> Alcotest.fail "the form closed"

(* Submit, then declare against [current] the way the key loop does. *)
let declare ?(current = fixture) form keys =
  F.declare_on ~inherited_home (submitted (press form keys)) current

let refusal = function
  | Error form -> form
  | Ok { F.id; _ } -> Alcotest.failf "%s was declared" id

let row_with prefix form =
  List.exists (fun row -> String.starts_with ~prefix row) (F.rows form)

let row_mentions text form =
  let contains row =
    let n = String.length text in
    let rec at i = i + n <= String.length row && (String.sub row i n = text || at (i + 1)) in
    at 0
  in
  List.exists contains (F.rows form)

let account_home text id =
  match Otoml.Parser.from_string_result text with
  | Ok toml ->
    Otoml.find_opt toml (fun v -> Otoml.get_string v) [ "providers"; id; "account-home" ]
  | Error _ -> None

let test_the_id_follows_the_chosen_provider () =
  let form = opened () in
  Alcotest.(check bool) "starts on the first provider with its next id" true
    (row_mentions "codex_subscription_2" form);
  let form = editing (press form [ "right" ]) in
  Alcotest.(check bool) "right moves to the next provider and its id" true
    (row_mentions "codex_acct1_2" form);
  let form = editing (press form [ "left"; "left" ]) in
  Alcotest.(check bool) "left wraps to the last provider" true
    (row_mentions "claude_code_2" form);
  let form = editing (press form [ "\r"; "\127"; "\127" ]) in
  let form = editing (press form (typed "_work" @ [ "up" ])) in
  let form = editing (press form [ "right" ]) in
  Alcotest.(check bool) "a typed id stays when the provider changes" true
    (row_mentions "claude_code_work" form)

let test_submit_declares_against_the_current_file () =
  let keys = [ "\r"; "enter" ] @ typed "~/.codex-account2" @ [ "\r" ] in
  (* Someone added a comment and a provider while the form stood open. *)
  let current =
    fixture
    ^ {|
# added while the form was open
[providers.later]
protocol = "claude-code"
command = "claude"
is-non-interactive = true
|}
  in
  match declare ~current (opened ()) keys with
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (F.rows form))
  | Ok { F.id; text; sign_in } ->
    Alcotest.(check string) "the suggested id" "codex_subscription_2" id;
    Alcotest.(check bool) "the change made meanwhile is kept" true
      (String.starts_with ~prefix:current text);
    Alcotest.(check (option string)) "the home is expanded"
      (Some "/home/op/.codex-account2") (account_home text id);
    (match Runtime_toml.parse_string text with
     | Error _ -> Alcotest.fail "the declared text does not load"
     | Ok config ->
       Alcotest.(check bool) "the new provider binds the base's model" true
         (List.exists
            (fun (b : Runtime_schema.binding) ->
              b.provider_id = "codex_subscription_2" && b.model_id = "gpt-5.6")
            config.Runtime_schema.bindings));
    Alcotest.(check (option string)) "the sign-in is a shell command for that home"
      (Some "CODEX_HOME=/home/op/.codex-account2 codex login")
      (Option.map (fun c -> String.concat "" (String.split_on_char '\'' c)) sign_in)

let test_a_home_with_a_space_is_one_argument () =
  let keys = [ "\r"; "\r" ] @ typed "/home/op/My Codex" @ [ "\r" ] in
  match declare (opened ()) keys with
  | Ok { F.sign_in = Some command; _ } ->
    Alcotest.(check string) "the home is quoted"
      "CODEX_HOME='/home/op/My Codex' codex login" command
  | Ok { F.sign_in = None; _ } -> Alcotest.fail "no sign-in for Codex"
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (F.rows form))

let test_a_refusal_keeps_the_form_on_its_field () =
  let form =
    refusal (declare (opened ()) ([ "\r"; "\r" ] @ typed "/home/op/.codex-account1" @ [ "\r" ]))
  in
  Alcotest.(check bool) "the reason is on the form" true (row_with "  ! " form);
  Alcotest.(check bool) "the cursor waits on the home" true (F.field form = F.Location);
  let keys =
    [ "up" ] @ List.init 20 (fun _ -> "\127") @ typed "codex_acct1" @ [ "\r" ]
    @ List.init 30 (fun _ -> "\127") @ typed "/home/op/.c3" @ [ "\r" ]
  in
  let form = refusal (F.declare_on ~inherited_home (submitted (press form keys)) fixture) in
  Alcotest.(check bool) "an id already used sends the cursor to the id" true
    (F.field form = F.Id)

let test_a_provider_gone_from_the_file_is_refused () =
  (* The provider the form was opened on was renamed meanwhile. *)
  let current =
    String.concat "\n"
      (List.filter_map
         (fun line ->
           if String.starts_with ~prefix:"[codex_subscription" line then None
           else if line = "[providers.codex_subscription]" then Some "[providers.gone]"
           else Some line)
         (String.split_on_char '\n' fixture))
  in
  let form =
    refusal (declare ~current (opened ()) ([ "\r"; "\r" ] @ typed "/home/op/.c9" @ [ "\r" ]))
  in
  Alcotest.(check bool) "the cursor goes back to the provider" true (F.field form = F.Base)

let test_esc_abandons () =
  match press (opened ()) (typed "x" @ [ "esc" ]) with
  | F.Cancelled -> ()
  | F.Editing _ | F.Submitted _ -> Alcotest.fail "esc did not close the form"

let test_a_paste_is_one_line () =
  let form = editing (press (opened ()) [ "\r"; "\r" ]) in
  let form = F.paste form "/home/op/.codex-pasted\n" in
  Alcotest.(check bool) "the newline a copied path carries is dropped" true
    (row_mentions "/home/op/.codex-pasted" form);
  match F.declare_on ~inherited_home (submitted (F.key form "\r")) fixture with
  | Ok { F.text; id; _ } ->
    Alcotest.(check (option string)) "and the home is written without it"
      (Some "/home/op/.codex-pasted") (account_home text id)
  | Error _ -> Alcotest.fail "the pasted home did not declare"

let test_antigravity_has_no_sign_in_after_the_save () =
  let current =
    fixture
    ^ {|
[providers.agy]
protocol = "antigravity-cli"
command = "agy"
is-non-interactive = true
timeout-s = 180.0

[providers.agy.credentials]
type = "file"
path = "/home/op/.agy/token"

[models.flash]
api-name = "gemini-3.7-flash-high"
max-context = 1000000
tools-support = true

[agy.flash]
|}
  in
  let form =
    match F.open_on ~home_dir:"/home/op" current with
    | Ok form -> form
    | Error reason -> Alcotest.fail reason
  in
  let form = editing (press form [ "left" ]) in
  match F.declare_on ~inherited_home (submitted (press form ([ "\r"; "\r" ] @ typed "/home/op/.agy2/token" @ [ "\r" ]))) current with
  | Ok { F.sign_in; _ } ->
    Alcotest.(check (option string)) "the OAuth file already exists" None sign_in
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (F.rows form))

let test_a_name_from_the_file_cannot_colour_the_pane () =
  let form = editing (press (opened ()) [ "left" ]) in
  Alcotest.(check bool) "the escape in the display name is not drawn" false
    (List.exists (fun row -> String.contains row '\027') (F.rows form))

let muse_current ~command =
  Printf.sprintf
    {|[providers.muse_personal]
display-name = "Muse"
protocol = "muse-serve"
command = "%s"
is-non-interactive = true

[models.muse_fixture]
api-name = "muse-fixture-1"
max-context = 200000
max-prompt-bytes = 1048576
tools-support = true

[muse_personal.muse_fixture]
|}
    command
let declare_muse_sign_in current =
  let form =
    match F.open_on ~home_dir:"/home/op" current with
    | Ok form -> form
    | Error reason -> Alcotest.fail reason
  in
  match F.declare_on ~inherited_home (submitted (press form ([ "\r"; "\r" ] @ typed "/home/op/.muse-account2" @ [ "\r" ]))) current with
  | Ok { F.sign_in; _ } -> sign_in
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (F.rows form))
(* PATH, MUSE_INSTALL_DIR and HOME decide the hinted executable; hold all
   three so the suite passes with or without a Muse install around. *)
let with_muse_env ~path ~install_dir ~home f =
  let root = Filename.temp_dir "masc-muse-hint-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    Masc_test_deps.with_process_env "PATH" (Some path) (fun () ->
      Masc_test_deps.with_process_env "MUSE_INSTALL_DIR" install_dir (fun () ->
        Masc_test_deps.with_process_env "HOME" (Some home) (fun () -> f root))))
let write_executable path =
  let channel = open_out path in
  close_out channel;
  Unix.chmod path 0o755
let test_muse_sign_in_sets_xdg_roots_at_the_new_account () =
  with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun _ ->
    let quoted = "'/home/op/.muse-account2'" in
    Alcotest.(check (option string)) "HOME and XDG roots select the new account"
      (Some
         (Printf.sprintf
            "HOME=%s XDG_CONFIG_HOME=%s/.config XDG_DATA_HOME=%s/.local/share XDG_CACHE_HOME=%s/.cache XDG_STATE_HOME=%s/.local/state XDG_RUNTIME_DIR=%s/.local/run muse login"
            quoted quoted quoted quoted quoted quoted))
      (declare_muse_sign_in (muse_current ~command:"muse")))
let test_muse_sign_in_prefers_the_resolved_executable () =
  with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun root ->
    let bindir = Filename.concat root "bin" in
    Unix.mkdir bindir 0o755;
    let resolved = Filename.concat bindir "muse" in
    write_executable resolved;
    Masc_test_deps.with_process_env "PATH" (Some bindir) (fun () ->
      match declare_muse_sign_in (muse_current ~command:"muse") with
      | None -> Alcotest.fail "expected a sign-in hint"
      | Some hint ->
        Alcotest.(check bool) "resolved executable signs in"
          true
          (String.ends_with ~suffix:(resolved ^ " login") hint)))
let test_muse_sign_in_keeps_the_configured_absolute_command () =
  with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun _ ->
    match declare_muse_sign_in (muse_current ~command:"/custom/muse") with
    | None -> Alcotest.fail "expected a sign-in hint"
    | Some hint ->
      Alcotest.(check bool) "configured command signs in"
        true
        (String.ends_with ~suffix:"/custom/muse login" hint))

let test_a_file_with_no_client_has_nothing_to_copy () =
  match
    F.open_on
      "[providers.ollama]\nprotocol = \"ollama-http\"\nendpoint = \"http://localhost:11434\"\n"
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a file with no official client opened the form"

let () =
  Alcotest.run "tui_runtime_account_form"
    [ ( "form"
      , [ Alcotest.test_case "the id follows the chosen provider" `Quick
            test_the_id_follows_the_chosen_provider
        ; Alcotest.test_case "submit declares against the current file" `Quick
            test_submit_declares_against_the_current_file
        ; Alcotest.test_case "a home with a space is one argument" `Quick
            test_a_home_with_a_space_is_one_argument
        ; Alcotest.test_case "a refusal keeps the form on its field" `Quick
            test_a_refusal_keeps_the_form_on_its_field
        ; Alcotest.test_case "a provider gone from the file is refused" `Quick
            test_a_provider_gone_from_the_file_is_refused
        ; Alcotest.test_case "esc abandons" `Quick test_esc_abandons
        ; Alcotest.test_case "a paste is one line" `Quick test_a_paste_is_one_line
        ; Alcotest.test_case "antigravity has no sign-in after the save" `Quick
            test_antigravity_has_no_sign_in_after_the_save
        ; Alcotest.test_case "a name from the file cannot colour the pane" `Quick
            test_a_name_from_the_file_cannot_colour_the_pane
        ; Alcotest.test_case "muse sign-in sets XDG roots at the new account" `Quick
            test_muse_sign_in_sets_xdg_roots_at_the_new_account
        ; Alcotest.test_case "muse sign-in prefers the resolved executable" `Quick
            test_muse_sign_in_prefers_the_resolved_executable
        ; Alcotest.test_case "muse sign-in keeps the configured absolute command" `Quick
            test_muse_sign_in_keeps_the_configured_absolute_command
        ; Alcotest.test_case "a file with no client has nothing to copy" `Quick
            test_a_file_with_no_client_has_nothing_to_copy
        ] )
    ]
