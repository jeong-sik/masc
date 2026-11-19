let check = Alcotest.check
let string = Alcotest.string
let int = Alcotest.int
let bool = Alcotest.bool

module T = Masc_tui_model_runtime_table

let parse lines =
  let providers = ["ollama_cloud"; "local"] in
  let declared = List.concat_map (fun id ->
    if List.exists (fun line -> String.equal line ("[providers." ^ id ^ "]")) lines
    then [] else ["[providers." ^ id ^ "]";
      "protocol = \"openai-compatible-http\""; "kind = \"openai_compat\"";
      "endpoint = \"http://localhost:9000/v1\""]) providers in
  let lines = List.filter (fun line -> line <> "base-url = \"https://ollama.com\"") lines in
  let lines = List.concat_map (fun line -> if line = "[providers.ollama_cloud]" then
    [line; "protocol = \"openai-compatible-http\""; "kind = \"openai_compat\"";
     "endpoint = \"http://localhost:9000/v1\""] else [line]) lines in
  let lines = lines @ declared in
  let config = Runtime_toml.parse_string (String.concat "\n" lines) |> Result.get_ok in
  let account_groups = Runtime_wizard_inventory.account_groups_json config
    |> Yojson.Safe.Util.to_list |> List.map (fun group ->
      Yojson.Safe.Util.(group |> member "integration_ids" |> to_list |> List.map to_string)) in
  match T.parse ~account_groups lines with
  | Ok rows -> rows | Error detail -> Alcotest.fail detail

let sample =
  [ "[models.alpha]"
  ; "api-name = \"alpha-v2\""
  ; "# reasoning-effort = \"high\"   <- commented out, not a value"
  ; "reasoning-effort = \"low\""
  ; "temperature = 0.7"
  ; ""
  ; "[models.alpha.capabilities]"
  ; "max-output-tokens = 999"
  ; ""
  ; "[ollama_cloud.alpha]"
  ; "max-tokens = 16384"
  ; ""
  ; "[models.beta]"
  ; "streaming = true"
  ; ""
  ; "[ollama_cloud.beta]"
  ; "max-concurrent = 2"
  ; ""
  ; "[providers.ollama_cloud]"
  ; "base-url = \"https://ollama.com\""
  ; ""
  ; "[voice.tts]"
  ; "enabled = true"
  ]

let row_named rows name =
  match List.find_opt (fun (r : T.row) -> String.equal r.T.model name) rows with
  | Some r -> r
  | None -> Alcotest.failf "row %S is missing" name

let test_reads_both_tables () =
  let alpha = row_named (parse sample) "alpha" in
  check string "provider" "ollama_cloud" alpha.T.provider;
  check string "api name" "alpha-v2" (Option.get alpha.T.api_name);
  check
    string
    "effort comes from the models table"
    "low"
    (Option.get alpha.T.reasoning_effort);
  check string "temperature comes from the models table" "0.7"
    (Option.get alpha.T.temperature);
  check int "max-tokens comes from the binding" 16384 (Option.get alpha.T.max_tokens)

let test_absent_knobs_stay_absent () =
  let beta = row_named (parse sample) "beta" in
  check bool "no effort" true (Option.is_none beta.T.reasoning_effort);
  check bool "no temperature" true (Option.is_none beta.T.temperature);
  check bool "no max-tokens" true (Option.is_none beta.T.max_tokens)

(* [providers.X] and [voice.Y] have the same two-part shape as a binding.
   Before the models-table pairing they landed in the table as rows with two
   empty knob columns, which reads as "a model nobody configured". *)
let test_non_model_sections_are_not_rows () =
  let names = List.map (fun (r : T.row) -> r.T.model) (parse sample) in
  check bool "no provider row" false (List.mem "ollama_cloud" names);
  check bool "no voice row" false (List.mem "tts" names);
  check int "only the two models" 2 (List.length names)

(* [models.alpha.capabilities] carries its own max-tokens. Treating the
   sub-table as a continuation of [models.alpha] would read 999 for a
   binding whose real cap is 16384. *)
let test_sub_tables_do_not_leak () =
  let alpha = row_named (parse sample) "alpha" in
  check int "binding value wins" 16384 (Option.get alpha.T.max_tokens)

let test_commented_lines_are_not_values () =
  let lines =
    [ "[models.gamma]"; "# reasoning-effort = \"max\""; "[ollama_cloud.gamma]"; "max-tokens = 1" ]
  in
  let gamma = row_named (parse lines) "gamma" in
  check bool "comment ignored" true (Option.is_none gamma.T.reasoning_effort)

let test_accounts_and_sets () =
  let lines = [
    "[models.shared]"; "max-context = 500000";
    "[model_sets.family]"; "models = ['shared']";
    "[providers.first]"; "protocol = 'codex-app-server'"; "command = 'codex'";
    "is-non-interactive = true"; "model-set = 'family'";
    "[providers.second]"; "protocol = 'codex-app-server'"; "command = 'codex'";
    "is-non-interactive = true"; "model-set = 'family'";
    "[second.shared]"; "max-context = 272000";
  ] in
  let rows = parse lines in
  check (Alcotest.list string) "both account bindings, including implicit set member"
    ["first"; "second"] (List.map (fun (r:T.row) -> r.provider) rows);
  check (Alcotest.list (Alcotest.option (Alcotest.pair string int))) "binding context is account scoped"
    [Some ("model", 500000); Some ("binding", 272000)]
    (List.map (fun (r:T.row) -> r.context) rows)

(* A provider id does not name its account: on 2026-10-08 one Codex login sat
   under three ids and read as three accounts. Ids that share an account-home
   name each other. *)
let test_same_login_names_other_ids () =
  let provider id home =
    [ "[providers." ^ id ^ "]"; "protocol = 'codex-app-server'"; "command = 'codex'";
      "is-non-interactive = true"; "model-set = 'family'" ]
    @ (match home with
       | Some home -> [ "account-home = '" ^ home ^ "'" ]
       | None -> [])
  in
  let lines =
    [ "[models.shared]"; "max-context = 500000";
      "[model_sets.family]"; "models = ['shared']" ]
    @ provider "codex_a" (Some "/tmp/login-one")
    @ provider "codex_b" (Some "/tmp/login-one")
    @ provider "codex_c" (Some "/tmp/login-two")
    @ provider "codex_d" None
  in
  check
    (Alcotest.list (Alcotest.pair string (Alcotest.list string)))
    "ids on one account-home name each other and nobody else"
    [ "codex_a", [ "codex_b" ]; "codex_b", [ "codex_a" ]; "codex_c", []; "codex_d", [] ]
    (List.map (fun (r : T.row) -> r.provider, r.same_login) (parse lines))

let test_server_owned_membership () =
  let lines = ["[models.shared]"; "max-context=8192";
    "[providers.a]"; "protocol='codex-app-server'"; "command='codex'";
    "is-non-interactive=true"; "account-home='/client/distinct-a'";
    "[providers.b]"; "protocol='codex-app-server'"; "command='codex'";
    "is-non-interactive=true"; "account-home='/client/distinct-b'";
    "[a.shared]"; "[b.shared]"] in
  (* The client consumes membership as evidence; it cannot recompute the
     server environment. An unknown member instead refuses mismatched source. *)
  let rows = T.parse ~account_groups:[["a";"b"]] lines |> Result.get_ok in
  check (Alcotest.list string) "server membership controls peers"
    ["b"] (List.hd rows).same_login;
  check bool "foreign-source membership rejected" true
    (Result.is_error (T.parse ~account_groups:[["a";"missing"]] lines))

let test_one_login_is_adjacent_and_tagged () =
  let provider id home =
    [ "[providers." ^ id ^ "]"; "protocol = 'codex-app-server'"; "command = 'codex'";
      "is-non-interactive = true"; "model-set = 'family'";
      "account-home = '" ^ home ^ "'" ]
  in
  let rows =
    parse
      ([ "[models.shared]"; "max-context = 500000";
         "[model_sets.family]"; "models = ['shared']" ]
       @ provider "codex_a" "/tmp/login-one"
       @ provider "codex_m" "/tmp/login-two"
       @ provider "codex_z" "/tmp/login-one")
  in
  check (Alcotest.list string) "the two ids of one login are adjacent"
    [ "codex_a"; "codex_z"; "codex_m" ]
    (List.map (fun (r : T.row) -> r.provider) rows);
  check (Alcotest.list (Alcotest.option int)) "a shared login is numbered, a single id is not"
    [ Some 1; Some 1; None ]
    (List.map (fun (r : T.row) -> r.login_group) rows);
  check (Alcotest.list string) "without a label the column shows the group"
    [ "codex_a #1"; "codex_z #1"; "codex_m" ]
    (List.map T.provider_text rows);
  let labelled =
    List.map (fun (r : T.row) -> { r with account_label = Some "someone" }) rows
  in
  check (Alcotest.list string) "a label replaces the group number"
    [ "codex_a someone"; "codex_z someone"; "codex_m someone" ]
    (List.map T.provider_text labelled);
  (* The drawn column is the measured column: every row starts its model
     name at the same cell with the label in place. *)
  let width = 120 in
  check bool "the labelled table fits a wide pane" true (T.fits ~width labelled);
  (match T.render ~width ~pane:width labelled with
   | _header :: lines ->
     let model_at line =
       let rec find i =
         if i + 6 > String.length line then -1
         else if String.sub line i 6 = "shared" then i else find (i + 1) in
       find 0 in
     check (Alcotest.list int) "model names line up under one column"
       (List.map (fun _ -> model_at (List.hd lines)) lines)
       (List.map model_at lines)
   | [] -> Alcotest.fail "no table was drawn")

let test_keepers_on_login () =
  let alpha = row_named (parse sample) "alpha" in
  let row = { alpha with provider = "codex_a"; same_login = [ "codex_z" ] } in
  let assignments =
    [ "zed", "codex_z.model"; "amy", "codex_a.model"; "lane-user", "sonnet-lane";
      "other", "codex_ab.model"; "dotted", "codex_a.extra.model"; "unknown", "codex_a.undeclared" ]
  in
  check (Alcotest.list string) "direct assignments on any id of the login, sorted"
    [ "amy"; "zed" ] (T.keepers_on_login ~rows:[{row with model="model"}; {row with provider="codex_z";model="model"};
      {row with provider="codex_a.extra";model="model";same_login=[]}]
      ~assignments row);
  check string "the count comes before the names"
    "Keepers assigned directly (lanes not counted): 2 - amy, zed"
    (List.nth (T.detail_lines ~keepers:[ "amy"; "zed" ] row) 2);
  check string "an empty login says none"
    "Keepers assigned directly (lanes not counted): none"
    (List.nth (T.detail_lines ~keepers:[] row) 2)

let test_invalid_is_error () =
  match T.parse ["[models.broken"] with
  | Error _ -> () | Ok _ -> Alcotest.fail "bad source was presented as an empty model list"

let test_exact_runtime_lookup () =
  let row = row_named (parse sample) "alpha" in
  let rows = [{row with provider = "account-one"; model = "model.6"};
              {row with provider = "account-two"; model = "model.6"}] in
  let selected = T.find_runtime ~runtime_id:"account-two.model.6" rows in
  check (Alcotest.option int) "exact account and dotted model" (Some 1)
    (Option.map fst selected);
  check bool "no prefix guess" true
    (Option.is_none (T.find_runtime ~runtime_id:"account-two.model" rows));
  check bool "missing binding stays missing" true
    (Option.is_none (T.find_runtime ~runtime_id:"account-three.model.6" rows))

(* QA N10: the first j scrolled the column names off and every j moved the
   whole table under a still cursor. The window a pane of [height] lines
   draws moves only when the selected binding leaves it, so the names on
   line 0 stay while the selection is inside the first window and Home
   brings them back. *)
let test_the_window_moves_only_when_the_selection_leaves_it () =
  let window ?(table = true) ?(starts = []) ~total ~height ~cursor scroll =
    T.window ~table ~starts ~total ~height ~cursor scroll
  in
  (* A table of 30 bindings under its column names: 31 lines, 10 drawn. *)
  let table ~cursor scroll = window ~total:31 ~height:10 ~cursor scroll in
  List.iter
    (fun cursor ->
      check int (Printf.sprintf "binding %d in the first window keeps the names" cursor) 0
        (table ~cursor 0))
    (List.init 9 Fun.id);
  check int "the tenth binding moves the window one line" 1 (table ~cursor:9 0);
  check int "a step inside the window moves only the mark" 5 (table ~cursor:7 5);
  check int "a step below the window brings its line to the bottom" 7 (table ~cursor:15 5);
  check int "Home brings the names back" 0 (table ~cursor:0 20);
  check int "End shows the last binding at the bottom" 21 (table ~cursor:29 0);
  check int "a stale scroll is held inside the document" 21 (table ~cursor:29 99);
  (* Stacked items of four lines with a blank between: a window that shows
     any line of the selected item stands, so its body can be read. *)
  let stacked ~cursor scroll =
    window ~table:false ~starts:[ 0; 5; 10 ] ~total:14 ~height:3 ~cursor scroll
  in
  check int "an item partly shown keeps the window" 2 (stacked ~cursor:0 2);
  check int "an item below the window shows its first line at the bottom" 3 (stacked ~cursor:1 0);
  check int "an item above the window comes to its first line" 5 (stacked ~cursor:1 11)

(* QA N10 at 80x24: the stacked items took three lines each, and PgDn walked
   the document, which the window pulled straight back to the selected
   item: the selection never moved. A page is the bindings the window
   holds, and only an item taller than the pane is read line by line. *)
let test_a_page_counts_the_bindings_the_window_holds () =
  let drawn ?(table = true) ?(starts = []) ~total ~height first =
    T.drawn_bindings ~table ~starts ~total ~height ~first
  in
  check int "the first window holds the rows under the names" 9 (drawn ~total:31 ~height:10 0);
  check int "a window past the names holds a row per line" 10 (drawn ~total:31 ~height:10 5);
  check int "the last window holds what is left" 4 (drawn ~total:31 ~height:10 27);
  let starts = [ 0; 3; 6; 9; 12 ] in
  check int "stacked items whose first line is in the window" 3
    (drawn ~table:false ~starts ~total:14 ~height:8 0);
  check int "an item cut at the top is not counted" 2
    (drawn ~table:false ~starts ~total:14 ~height:6 1);
  check int "a window inside one item still pages by one" 1
    (drawn ~table:false ~starts:[ 0; 20 ] ~total:30 ~height:5 2);
  let reads ?(table = false) ~starts ~total ~height cursor =
    T.reads_selected ~table ~starts ~total ~height cursor
  in
  check bool "a short stacked item walks bindings" false (reads ~starts ~total:14 ~height:8 1);
  check bool "a stacked item taller than the pane is read" true
    (reads ~starts:[ 0; 20 ] ~total:30 ~height:5 0);
  check bool "a table row never is" false (reads ~table:true ~starts:[] ~total:31 ~height:1 3)

(* The line a binding is drawn on: under the column names in the table, the
   item's first line when stacked. A binding is on screen when this line is
   in the window, the way [drawn_bindings] counts it. *)
let binding_line ~table ~starts binding =
  if table then binding + 1 else List.nth starts binding

let shown ~table ~starts ~height ~first binding =
  let line = binding_line ~table ~starts binding in
  line >= first && line < first + height

(* RFC tui-one-screen-grammar §3.1 on the models pane, put together the way
   the dispatcher does it: the window the pane draws, the bindings that
   window holds, a page of them less one, and the window that follows the
   landing. From every selection and every window that shows it, PgDn keeps
   the binding drawn last on screen and lands on a binding the pane draws.
   The parts were tested one by one; this is the decision they make. *)
let test_a_page_down_keeps_the_binding_drawn_last () =
  let check_pane ~label ~table ~starts ~total ~count ~height =
    for cursor = 0 to count - 1 do
      if not (T.reads_selected ~table ~starts ~total ~height cursor) then
        for scroll = 0 to total do
          let first = T.window ~table ~starts ~total ~height ~cursor scroll in
          let last =
            List.fold_left
              (fun last binding ->
                if shown ~table ~starts ~height ~first binding then binding else last)
              (-1) (List.init count Fun.id)
          in
          let drawn = T.drawn_bindings ~table ~starts ~total ~height ~first in
          let landing = Int.min (count - 1) (cursor + Masc_tui_scroll.page_step ~height:drawn) in
          let next = T.window ~table ~starts ~total ~height ~cursor:landing first in
          let at = Printf.sprintf "%s %d tall, binding %d, window %d" label height cursor first in
          (* A window of one binding pages by one and keeps nothing. *)
          check bool (at ^ ": the binding drawn last stays") true
            (drawn < 2 || last < 0 || shown ~table ~starts ~height ~first:next last);
          check bool (at ^ ": the landing is drawn") true
            (shown ~table ~starts ~height ~first:next landing)
        done
    done
  in
  List.iter
    (fun count ->
      List.iter
        (fun height ->
          check_pane ~label:(Printf.sprintf "table of %d" count) ~table:true ~starts:[]
            ~total:(count + 1) ~count ~height)
        [ 2; 3; 4; 9; 14 ])
    [ 1; 2; 5; 30 ];
  (* Stacked items of one height: [lines] lines and the blank after them. *)
  List.iter
    (fun (count, lines) ->
      let starts = List.init count (fun index -> index * (lines + 1)) in
      let total = (count * (lines + 1)) - 1 in
      List.iter
        (fun height ->
          check_pane ~label:(Printf.sprintf "%d items of %d lines" count lines) ~table:false
            ~starts ~total ~count ~height)
        [ lines; lines + 1; 7; 15 ])
    [ 1, 2; 6, 2; 40, 2; 12, 3 ]

let () =
  Alcotest.run
    "masc_tui_model_runtime_table"
    [ ( "accounts", [ Alcotest.test_case "settings target exact account" `Quick test_exact_runtime_lookup;
       Alcotest.test_case "shared model preserves each account and context" `Quick test_accounts_and_sets;
       Alcotest.test_case "server-owned membership" `Quick test_server_owned_membership;
       Alcotest.test_case "ids on one login name each other" `Quick test_same_login_names_other_ids;
       Alcotest.test_case "one login is adjacent and tagged" `Quick test_one_login_is_adjacent_and_tagged;
       Alcotest.test_case "keepers on a login" `Quick test_keepers_on_login;
       Alcotest.test_case "invalid source is visible" `Quick test_invalid_is_error ])
    ; ( "parse"
      , [ Alcotest.test_case "reads both tables" `Quick test_reads_both_tables
        ; Alcotest.test_case "absent knobs stay absent" `Quick test_absent_knobs_stay_absent
        ; Alcotest.test_case
            "non-model sections are not rows"
            `Quick
            test_non_model_sections_are_not_rows
        ; Alcotest.test_case "sub-tables do not leak" `Quick test_sub_tables_do_not_leak
        ; Alcotest.test_case "commented lines are not values" `Quick test_commented_lines_are_not_values
        ] )
    ; ( "render"
      , [ Alcotest.test_case "the window moves only when the selection leaves it" `Quick
            test_the_window_moves_only_when_the_selection_leaves_it
        ; Alcotest.test_case "a page counts the bindings the window holds" `Quick
            test_a_page_counts_the_bindings_the_window_holds
        ; Alcotest.test_case "a page down keeps the binding drawn last" `Quick
            test_a_page_down_keeps_the_binding_drawn_last ] )
    ]
