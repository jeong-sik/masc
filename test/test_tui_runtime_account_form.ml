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
      | F.Cancelled | F.Submitted _ | F.Copy _ -> outcome)
    (F.Editing form) keys

let editing = function
  | F.Editing form -> form
  | F.Cancelled -> Alcotest.fail "the form closed"
  | F.Submitted _ -> Alcotest.fail "the form submitted"
  | F.Copy _ -> Alcotest.fail "the form copied"

let submitted = function
  | F.Submitted form -> form
  | F.Editing _ -> Alcotest.fail "enter on the last field did not submit"
  | F.Cancelled -> Alcotest.fail "the form closed"
  | F.Copy _ -> Alcotest.fail "the form copied"

(* Submit, then declare against [current] the way the key loop does. *)
let declare ?(current = fixture) form keys =
  F.declare_on ~inherited_home (submitted (press form keys)) current

let refusal = function
  | Error form -> form
  | Ok { F.id; _ } -> Alcotest.failf "%s was declared" id

(* The body of an 80-column and of a 120-column pane, as the frame gives it. *)
let width_80 = Masc_tui_frame.inner_width ~cols:80
let width_120 = Masc_tui_frame.inner_width ~cols:120

let rows form = F.rows ~width:width_80 form

let contains text row =
  let n = String.length text in
  let rec at i = i + n <= String.length row && (String.sub row i n = text || at (i + 1)) in
  at 0

let row_with prefix form =
  List.exists (fun row -> String.starts_with ~prefix row) (rows form)

let row_mentions text form = List.exists (contains text) (rows form)

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
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form))
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
      (Some "(export CODEX_HOME=/home/op/.codex-account2 && codex login)")
      (Option.map
         (fun s -> String.concat "" (String.split_on_char '\'' (F.command s)))
         sign_in)

let test_a_home_with_a_space_is_one_argument () =
  let keys = [ "\r"; "\r" ] @ typed "/home/op/My Codex" @ [ "\r" ] in
  match declare (opened ()) keys with
  | Ok { F.sign_in = Some s; _ } ->
    Alcotest.(check string) "the home is quoted"
      "(export CODEX_HOME='/home/op/My Codex' && codex login)" (F.command s);
    Alcotest.(check (option string)) "codex logs in by itself" None (F.then_type s)
  | Ok { F.sign_in = None; _ } -> Alcotest.fail "no sign-in for Codex"
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form))

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
  | F.Editing _ | F.Submitted _ | F.Copy _ -> Alcotest.fail "esc did not close the form"

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

let with_antigravity =
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

(* The form on [with_antigravity] with its Antigravity provider chosen: left
   from the first provider wraps to the last. *)
let opened_on_antigravity () =
  match F.open_on ~home_dir:"/home/op" with_antigravity with
  | Ok form -> editing (press form [ "left" ])
  | Error reason -> Alcotest.fail reason

let test_antigravity_has_no_sign_in_after_the_save () =
  let current = with_antigravity in
  let form = opened_on_antigravity () in
  match F.declare_on ~inherited_home (submitted (press form ([ "\r"; "\r" ] @ typed "/home/op/.agy2/token" @ [ "\r" ]))) current with
  | Ok { F.sign_in; _ } ->
    Alcotest.(check bool) "the OAuth file already exists" true (Option.is_none sign_in)
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form))

let test_a_name_from_the_file_cannot_colour_the_pane () =
  let form = editing (press (opened ()) [ "left" ]) in
  Alcotest.(check bool) "the escape in the display name is not drawn" false
    (List.exists (fun row -> String.contains row '\027') (rows form))

(* Every row fits the pane except the focused field showing [field_value]: a
   field keeps one row at any width, so a typed value longer than the pane is
   still cut there. *)
let fits ?(field_value = "") width form =
  List.iter
    (fun row ->
      let focused_field =
        field_value <> "" && String.starts_with ~prefix:"  > " row
        && String.ends_with ~suffix:field_value row
      in
      if (not focused_field) && Masc_tui_message_layout.display_width row > width then
        Alcotest.failf "a row is wider than the %d-cell pane, which cuts it: %S" width row)
    (F.rows ~width form)

(* A hint breaks at its spaces and each row starts with its indentation, so
   spaces say nothing about what was drawn: [text] without them has to be in
   the rows without them. *)
let without_spaces text = String.concat "" (String.split_on_char ' ' text)

let drawn_whole ~width text form =
  contains (without_spaces text) (without_spaces (String.concat "" (F.rows ~width form)))

let test_the_antigravity_hint_is_not_cut_at_80_columns () =
  let form = opened_on_antigravity () in
  fits width_80 form;
  Alcotest.(check bool) "credential_file stays whole on one row" true
    (row_mentions "credential_file" form);
  let one_row rows = List.exists (fun row -> contains "OAuth" row && contains "credential_file" row) rows in
  Alcotest.(check bool) "at 120 columns the hint still fits one row" true
    (one_row (F.rows ~width:width_120 form))

(* A home long enough to push the command past an 80-column row; one with
   spaces in it; and one whose quoted path alone is wider than a row, which
   can only be broken inside the path. *)
let long_homes =
  [ [], "/home/op/accounts/codex-second-login-for-the-review-team"
  ; [ "left" ], "/home/op/Claude Accounts/second login for the review team"
  ; ( []
    , "/home/op/"
      ^ String.concat "/" (List.init 5 (fun i -> Printf.sprintf "nested-directory-%d" i)) )
  ]

(* [bash -n] reads a command without running it, and answers 0 only when it
   parses. *)
let parses command =
  Sys.command (Printf.sprintf "bash -n -c %s 2>/dev/null" (Filename.quote command)) = 0

let command_label = "로그인: "

(* The command rows as the pane draws them, cut at [width], and what an
   operator copies off each: the row without its label and indentation. *)
let copied_command ~width form =
  let lead = "  " ^ command_label in
  let under = String.make (Masc_tui_message_layout.display_width lead) ' ' in
  let rec from = function
    | row :: next :: _ when String.starts_with ~prefix:lead row && String.starts_with ~prefix:under next ->
      [ row; next ]
    | row :: _ when String.starts_with ~prefix:lead row -> [ row ]
    | _ :: rest -> from rest
    | [] -> []
  in
  List.map
    (fun row ->
      let text = String.trim (Masc_tui_message_layout.fit_width row width) in
      if String.starts_with ~prefix:command_label text
      then
        String.trim
          (String.sub text (String.length command_label)
             (String.length text - String.length command_label))
      else text)
    (from (F.rows ~width form))

(* The command rows of [form], judged against [command]. *)
let check_command_rows ~drawn command form =
  match copied_command ~width:width_80 form with
  | [ one ] -> Alcotest.(check string) ("one row is the command: " ^ drawn) command one
  | [ setup; run ] ->
    Alcotest.(check bool) ("the first row alone does not parse: " ^ setup) false
      (parses setup);
    Alcotest.(check bool) ("the second row alone does not parse: " ^ run) false
      (parses run);
    let cut = String.ends_with ~suffix:"\xe2\x80\xa6" setup in
    Alcotest.(check bool) ("the rows together parse unless cut: " ^ drawn) (not cut)
      (parses (setup ^ "\n" ^ run));
    if not cut
    then Alcotest.(check string) "the rows are the command" command (setup ^ " " ^ run)
  | [] ->
    Alcotest.(check bool) "a long command directs to complete-command copying" true
      (row_mentions "전체 명령" form)
  | rows -> Alcotest.failf "the command took %d rows: %s" (List.length rows) drawn

(* A command copied off two rows that ran as two commands would sign the
   client in on the default login. Split or cut, no row alone parses; the
   rows together are the command the save prints, unless the pane cut the
   first one. The saved form draws the same command the same way. *)
let test_a_sign_in_command_runs_only_when_pasted_whole () =
  List.iter
    (fun (choose, home) ->
      let form = editing (press (opened ()) (choose @ [ "\r"; "\r" ] @ typed home)) in
      let submitted_form = submitted (F.key form "\r") in
      match F.declare_on ~inherited_home submitted_form fixture with
      | Ok { F.id; sign_in = Some s; _ } ->
        check_command_rows ~drawn:("typing " ^ home) (F.command s) form;
        check_command_rows ~drawn:("saved " ^ home) (F.command s)
          (F.saved submitted_form ~id s)
      | Ok { F.sign_in = None; _ } -> Alcotest.failf "no sign-in for %s" home
      | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form)))
    long_homes;
  Alcotest.(check bool) "a short command still parses on its one row" true
    (parses "(export CODEX_HOME='/home/op/.codex-2' && codex login)")

(* Declares [home] on the provider [choose] picks and opens the form on the
   save, the way the key loop does after the server saved it. *)
let saved_on ?(choose = []) home =
  let form = submitted (press (opened ()) (choose @ [ "\r"; "\r" ] @ typed home @ [ "\r" ])) in
  match F.declare_on ~inherited_home form fixture with
  | Ok { F.id; sign_in = Some s; _ } -> id, s, F.saved form ~id s
  | Ok { F.sign_in = None; id; _ } -> Alcotest.failf "no sign-in for %s" id
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form))

(* After the save the form holds the command until it is closed: [y] hands
   it over whole, and nothing typed changes what is shown. *)
let test_a_saved_form_copies_its_command_until_closed () =
  let id, s, form = saved_on "/home/op/.codex-account2" in
  Alcotest.(check bool) "the form is saved" true (F.is_saved form);
  Alcotest.(check bool) "the saved id is shown" true (row_mentions id form);
  Alcotest.(check bool) "the fields are gone" false (row_mentions "새 provider id" form);
  fits width_80 form;
  List.iter
    (fun key ->
      match F.key form key with
      | F.Copy (after, copied) ->
        Alcotest.(check string) (key ^ " copies the command the save printed") (F.command s)
          copied;
        Alcotest.(check bool) (key ^ " leaves the form open") true (F.is_saved after)
      | F.Editing _ | F.Cancelled | F.Submitted _ -> Alcotest.failf "%s did not copy" key)
    [ "y"; "Y" ];
  let before = rows form in
  let after_typing = editing (press form (typed "abc" @ [ "left"; "tab"; "backspace" ])) in
  Alcotest.(check (list string)) "typing changes nothing" before (rows after_typing);
  List.iter
    (fun key ->
      match F.key form key with
      | F.Cancelled -> ()
      | F.Editing _ | F.Submitted _ | F.Copy _ -> Alcotest.failf "%s did not close" key)
    [ "\r"; "esc" ]

let test_a_saved_claude_code_form_says_what_to_type () =
  let _, s, form = saved_on ~choose:[ "left" ] "/home/op/.claude-second" in
  Alcotest.(check (option string)) "claude signs in from inside" (Some "/login") (F.then_type s);
  Alcotest.(check bool) "the saved form says to type it" true (row_mentions "/login" form)

let test_a_long_refusal_wraps_under_its_mark () =
  let reason =
    String.concat "; "
      (List.init 3 (fun i ->
         Printf.sprintf "providers.codex_subscription_%d.account-home: must be an absolute path" i))
  in
  let form = F.refused (opened ()) reason in
  fits width_80 form;
  Alcotest.(check bool) "the reason is drawn whole" true (drawn_whole ~width:width_80 reason form);
  let rec after_mark = function
    | row :: next :: _ when String.starts_with ~prefix:"  ! " row -> Some next
    | _ :: rest -> after_mark rest
    | [] -> None
  in
  Alcotest.(check (option bool)) "the next row continues under the reason, not the mark"
    (Some true)
    (Option.map (String.starts_with ~prefix:"    ") (after_mark (rows form)))

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
  | Ok { F.sign_in; _ } -> Option.map F.command sign_in
  | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (F.rows ~width:240 form))
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
            "(unset META_API_KEY && export MUSE_NO_AUTO_UPDATE=1 TBH_CREDENTIAL_BACKEND=file HOME=%s XDG_CONFIG_HOME=%s/.config XDG_DATA_HOME=%s/.local/share XDG_CACHE_HOME=%s/.cache XDG_STATE_HOME=%s/.local/state XDG_RUNTIME_DIR=%s/.local/run && 'muse' login)"
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
          (String.ends_with ~suffix:(Filename.quote resolved ^ " login)") hint)))
let test_muse_sign_in_keeps_the_configured_absolute_command () =
  with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun _ ->
    match declare_muse_sign_in (muse_current ~command:"/custom path/muse") with
    | None -> Alcotest.fail "expected a sign-in hint"
    | Some hint ->
      Alcotest.(check bool) "configured command signs in"
        true
        (String.ends_with ~suffix:"'/custom path/muse' login)" hint))

let test_muse_sign_in_keeps_custom_commands_when_muse_is_installed () =
  with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun root ->
    let bindir = Filename.concat root "bin" in
    Unix.mkdir bindir 0o755;
    List.iter (fun name -> write_executable (Filename.concat bindir name))
      [ "muse"; "muse-custom" ];
    let cwd = Sys.getcwd () in
    Fun.protect ~finally:(fun () -> Sys.chdir cwd) (fun () ->
      Sys.chdir root;
      Masc_test_deps.with_process_env "PATH" (Some bindir) (fun () ->
        List.iter
          (fun (command, expected) ->
            match declare_muse_sign_in (muse_current ~command) with
            | None -> Alcotest.fail "expected a sign-in hint"
            | Some hint ->
              Alcotest.(check bool) ("configured client signs in: " ^ command) true
                (String.ends_with ~suffix:(Filename.quote expected ^ " login)") hint))
          [ "muse-custom", Filename.concat bindir "muse-custom"
          ; "./bin/muse-custom", Filename.concat (Sys.getcwd ()) "./bin/muse-custom"
          ])))

let test_muse_rows_state_the_authentication_boundary () =
  match F.open_on ~home_dir:"/home/op" (muse_current ~command:"muse") with
  | Error reason -> Alcotest.fail reason
  | Ok form ->
    let rows = F.rows ~width:240 form in
    List.iter (fun expected ->
      Alcotest.(check bool) expected true (List.mem expected rows))
      [ "  이 HOME의 .config/muse/auth.json 파일이 필요합니다."
      ; "  이 명령은 Keychain 대신 선택한 HOME의 파일에 로그인 정보를 저장합니다."
      ]

let test_muse_narrow_pane_hides_partial_commands_and_copies_whole () =
  let copied =
    with_muse_env ~path:"/nonexistent-path" ~install_dir:None ~home:"/nonexistent-home" (fun _ ->
      let current = muse_current ~command:"muse" in
      let form = match F.open_on ~home_dir:"/home/op" current with
        | Ok form -> form | Error reason -> Alcotest.fail reason in
      let form = submitted (press form
        ([ "\r"; "\r" ] @ typed "/home/op/.muse-account2" @ [ "\r" ])) in
      match F.declare_on ~inherited_home form current with
      | Error form -> Alcotest.failf "refused: %s" (String.concat " / " (rows form))
      | Ok { F.sign_in = None; _ } -> Alcotest.fail "missing Muse command"
      | Ok { F.id; sign_in = Some sign_in; _ } ->
        let saved = F.saved form ~id sign_in in
        List.iter (fun shown ->
          Alcotest.(check (list string)) "80-column pane exposes no partial command" []
            (copied_command ~width:width_80 shown);
          Alcotest.(check bool) "pane directs to full copy" true
            (row_mentions "전체 명령" shown);
          fits width_80 shown) [form; saved];
        match F.key saved "y" with
        | F.Copy (_, copied) ->
          Alcotest.(check string) "copy retains every environment assignment"
            (F.command sign_in) copied;
          Alcotest.(check bool) "file backend survives narrow rendering" true
            (contains "TBH_CREDENTIAL_BACKEND=file" copied);
          copied
        | F.Editing _ | F.Submitted _ | F.Cancelled -> Alcotest.fail "saved copy did not fire")
  in
  (* The fixture hides installed clients through PATH. Restore it before
     asking [parses] to find bash and check the copied command's syntax. *)
  Alcotest.(check bool) "whole copied command parses" true (parses copied)

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
        ; Alcotest.test_case "muse sign-in keeps custom commands when muse is installed" `Quick
            test_muse_sign_in_keeps_custom_commands_when_muse_is_installed
        ; Alcotest.test_case "muse rows state the authentication boundary" `Quick
            test_muse_rows_state_the_authentication_boundary
        ; Alcotest.test_case "muse narrow pane hides partial commands and copies whole" `Quick
            test_muse_narrow_pane_hides_partial_commands_and_copies_whole
        ; Alcotest.test_case "a file with no client has nothing to copy" `Quick
            test_a_file_with_no_client_has_nothing_to_copy
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "the antigravity hint is not cut at 80 columns" `Quick
            test_the_antigravity_hint_is_not_cut_at_80_columns
        ; Alcotest.test_case "a sign-in command runs only when pasted whole" `Quick
            test_a_sign_in_command_runs_only_when_pasted_whole
        ; Alcotest.test_case "a long refusal wraps under its mark" `Quick
            test_a_long_refusal_wraps_under_its_mark
        ] )
    ; ( "saved"
      , [ Alcotest.test_case "a saved form copies its command until closed" `Quick
            test_a_saved_form_copies_its_command_until_closed
        ; Alcotest.test_case "a saved claude code form says what to type" `Quick
            test_a_saved_claude_code_form_says_what_to_type
        ] )
    ]
