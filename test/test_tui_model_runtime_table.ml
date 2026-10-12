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
      , [] )
    ]
