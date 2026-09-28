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
  match F.open_on fixture with
  | Ok form -> form
  | Error reason -> Alcotest.failf "the form did not open: %s" reason

let typed text = List.init (String.length text) (fun i -> String.make 1 text.[i])

(* The fixture's codex_subscription has no account-home and runs on this. *)
let inherited_home = function
  | Runtime_account_declaration.Codex -> Some "/home/op/.codex"
  | Runtime_account_declaration.Claude_code | Runtime_account_declaration.Antigravity -> None

let press ?(home_dir = "/home/op") form keys =
  List.fold_left
    (fun outcome key ->
      match outcome with
      | F.Editing form -> F.key ~home_dir ~inherited_home form key
      | F.Cancelled | F.Declared _ -> outcome)
    (F.Editing form) keys

let editing = function
  | F.Editing form -> form
  | F.Cancelled -> Alcotest.fail "the form closed"
  | F.Declared { id; _ } -> Alcotest.failf "the form declared %s" id

let row_with prefix form =
  List.exists (fun row -> String.starts_with ~prefix row) (F.rows form)

let row_mentions text form =
  let contains row =
    let n = String.length text in
    let rec at i = i + n <= String.length row && (String.sub row i n = text || at (i + 1)) in
    at 0
  in
  List.exists contains (F.rows form)

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
  let form = editing (press form [ "\r"; "\127"; "\127" ] ) in
  let form = editing (press form (typed "_work" @ [ "up" ])) in
  let form = editing (press form [ "right" ]) in
  Alcotest.(check bool) "a typed id stays when the provider changes" true
    (row_mentions "claude_code_work" form)

let test_enter_on_the_last_field_declares () =
  let form = opened () in
  match press form ([ "\r"; "\r" ] @ typed "~/.codex-account2" @ [ "\r" ]) with
  | F.Declared { id; text; sign_in } ->
    Alcotest.(check string) "the suggested id" "codex_subscription_2" id;
    Alcotest.(check bool) "the file keeps what it had" true
      (String.starts_with ~prefix:fixture text);
    (match Runtime_toml.parse_string text with
     | Error _ -> Alcotest.fail "the declared text does not load"
     | Ok config ->
       Alcotest.(check bool) "the new provider binds the base's model" true
         (List.exists
            (fun (b : Runtime_schema.binding) ->
              b.provider_id = "codex_subscription_2" && b.model_id = "gpt-5.6")
            config.Runtime_schema.bindings));
    Alcotest.(check bool) "the sign-in names the expanded home" true
      (String.starts_with ~prefix:"CODEX_HOME=/home/op/.codex-account2 codex login"
         sign_in)
  | F.Editing _ -> Alcotest.fail "enter on the last field did not declare"
  | F.Cancelled -> Alcotest.fail "the form closed"

let test_a_refusal_keeps_the_form_on_its_field () =
  let form = opened () in
  let form =
    editing (press form ([ "\r"; "\r" ] @ typed "/home/op/.codex-account1" @ [ "\r" ]))
  in
  Alcotest.(check bool) "the reason is on the form" true (row_with "  ! " form);
  Alcotest.(check bool) "the cursor waits on the home" true (F.field form = F.Location);
  let form = editing (press form [ "up"; "up" ]) in
  let form =
    editing
      (press form ([ "down" ] @ List.init 20 (fun _ -> "\127") @ typed "codex_acct1" @ [ "\r" ]))
  in
  let form = editing (press form (List.init 30 (fun _ -> "\127") @ typed "/home/op/.c3" @ [ "\r" ])) in
  Alcotest.(check bool) "an id already used sends the cursor to the id" true
    (F.field form = F.Id)

let test_esc_abandons () =
  match press (opened ()) (typed "x" @ [ "esc" ]) with
  | F.Cancelled -> ()
  | F.Editing _ | F.Declared _ -> Alcotest.fail "esc did not close the form"

let test_a_paste_is_one_line () =
  let form = editing (press (opened ()) [ "\r"; "\r" ]) in
  let form = F.paste form "/home/op/.codex-pasted\n" in
  Alcotest.(check bool) "the newline a copied path carries is dropped" true
    (row_mentions "/home/op/.codex-pasted" form);
  match F.key ~home_dir:"/home/op" ~inherited_home form "\r" with
  | F.Declared { text; _ } ->
    Alcotest.(check (option string)) "and the home is written without it"
      (Some "/home/op/.codex-pasted")
      (match Otoml.Parser.from_string_result text with
       | Ok toml ->
         Otoml.find_opt toml (fun v -> Otoml.get_string v)
           [ "providers"; "codex_subscription_2"; "account-home" ]
       | Error _ -> None)
  | F.Editing _ | F.Cancelled -> Alcotest.fail "the pasted home did not declare"

let test_a_name_from_the_file_cannot_colour_the_pane () =
  let form = editing (press (opened ()) [ "left" ]) in
  Alcotest.(check bool) "the escape in the display name is not drawn" false
    (List.exists (fun row -> String.contains row '\027') (F.rows form))

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
        ; Alcotest.test_case "enter on the last field declares" `Quick
            test_enter_on_the_last_field_declares
        ; Alcotest.test_case "a refusal keeps the form on its field" `Quick
            test_a_refusal_keeps_the_form_on_its_field
        ; Alcotest.test_case "esc abandons" `Quick test_esc_abandons
        ; Alcotest.test_case "a paste is one line" `Quick test_a_paste_is_one_line
        ; Alcotest.test_case "a name from the file cannot colour the pane" `Quick
            test_a_name_from_the_file_cannot_colour_the_pane
        ; Alcotest.test_case "a file with no client has nothing to copy" `Quick
            test_a_file_with_no_client_has_nothing_to_copy
        ] )
    ]
