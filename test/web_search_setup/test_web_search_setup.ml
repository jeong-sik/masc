(* Web_search_setup writes the [web_search] section of a live runtime.toml.
   What these tests fix is that a bad edit does not reach the file, because
   nothing reads these keys until the server starts, and that an edit leaves
   everything it was not asked about as it was. *)

(* Every commit validates the whole file, not the section being edited, so a
   web-search write still needs a runtime.toml that loads. Same rows as
   test_voice_setup: a named [providers] entry keeps the capability gate
   satisfied. *)
let runtime_base =
  {|[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"
|}

(* A file with an operator's note above a measured setting, and a table that is
   not this module's. *)
let with_section =
  runtime_base
  ^ {|
# 2026-10-01: the local instance answers in 1.8 s, so it goes first.
[web_search]
searxng_url = "http://localhost:8888"
provider = "searxng"   # measured, do not reorder
timeout_sec = 20

[turn]
# unrelated to search
|}

let with_config contents f =
  let home = Filename.temp_file "web-search-setup" "" in
  Unix.unlink home;
  Unix.mkdir home 0o700;
  let path = Filename.concat home "runtime.toml" in
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  let rec cleanup target =
    match Unix.lstat target with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> cleanup (Filename.concat target name)) (Sys.readdir target);
      Unix.rmdir target
    | _ -> Unix.unlink target
  in
  Fun.protect ~finally:(fun () -> cleanup home) (fun () -> f path)

let read path = In_channel.with_open_bin path In_channel.input_all

let observe path =
  match Web_search_setup.observe ~runtime_config_path:path with
  | Ok observation -> observation
  | Error error -> Alcotest.fail (Web_search_setup.error_message error)

let apply path changes =
  Web_search_setup.apply
    ~runtime_config_path:path
    ~expected_revision:(observe path).Web_search_setup.revision
    changes

let applied path changes =
  match apply path changes with
  | Ok _revision -> ()
  | Error error -> Alcotest.fail (Web_search_setup.error_message error)

let comments contents =
  String.split_on_char '\n' contents
  |> List.filter (fun line ->
    let trimmed = String.trim line in
    String.length trimmed > 0 && Char.equal trimmed.[0] '#')

let contains haystack needle =
  let rec found index =
    index + String.length needle <= String.length haystack
    && (String.equal (String.sub haystack index (String.length needle)) needle
        || found (index + 1))
  in
  found 0

let providers first rest : Web_search_setup.providers = first, rest

(* ---- observe ---- *)

let test_observe_reads_the_section () =
  with_config with_section (fun path ->
    let { Web_search_setup.revision; settings; problems } = observe path in
    Alcotest.(check bool) "a revision is reported" true (String.length revision > 0);
    Alcotest.(check (option string))
      "searxng_url" (Some "http://localhost:8888") settings.Web_search_setup.searxng_url;
    Alcotest.(check (option string))
      "provider" (Some "searxng") settings.Web_search_setup.provider;
    Alcotest.(check (option int)) "timeout_sec" (Some 20) settings.Web_search_setup.timeout_sec;
    Alcotest.(check (option string))
      "an unset key is absent" None settings.Web_search_setup.provider_order;
    Alcotest.(check (list string)) "nothing the loader refuses" [] problems)

let test_a_file_without_the_section_observes_as_unset () =
  with_config runtime_base (fun path ->
    let { Web_search_setup.settings; problems; _ } = observe path in
    Alcotest.(check (option string)) "provider" None settings.Web_search_setup.provider;
    Alcotest.(check (option int)) "timeout_sec" None settings.Web_search_setup.timeout_sec;
    Alcotest.(check (list string)) "no problems" [] problems)

let test_a_key_of_the_wrong_type_is_reported () =
  let broken = runtime_base ^ "\n[web_search]\ntimeout_sec = \"soon\"\n" in
  with_config broken (fun path ->
    let { Web_search_setup.settings; problems; _ } = observe path in
    Alcotest.(check (option int))
      "a string where an integer belongs reads as absent" None
      settings.Web_search_setup.timeout_sec;
    Alcotest.(check bool)
      "and the file's problem names the key"
      true
      (List.exists (fun problem -> contains problem "web_search.timeout_sec") problems))

(* ---- writes ---- *)

let test_a_new_section_is_appended_and_nothing_else_moves () =
  with_config runtime_base (fun path ->
    applied
      path
      [ Web_search_setup.Set_provider Web_search_provider.Brave
      ; Web_search_setup.Set_timeout_sec 30
      ];
    let written = read path in
    Alcotest.(check bool)
      "every byte that was there is still there, in place"
      true
      (String.starts_with ~prefix:runtime_base written);
    let { Web_search_setup.settings; _ } = observe path in
    Alcotest.(check (option string))
      "provider" (Some "brave") settings.Web_search_setup.provider;
    Alcotest.(check (option int)) "timeout_sec" (Some 30) settings.Web_search_setup.timeout_sec)

let test_an_edit_keeps_the_notes_and_the_other_tables () =
  with_config with_section (fun path ->
    applied path [ Web_search_setup.Set_timeout_sec 30 ];
    let written = read path in
    Alcotest.(check (list string))
      "the operator's notes are still there, in order"
      (comments with_section)
      (comments written);
    Alcotest.(check bool)
      "a trailing comment on a line that was not changed is still there"
      true
      (contains written "provider = \"searxng\"   # measured, do not reorder");
    Alcotest.(check bool)
      "the searxng_url line is untouched"
      true
      (contains written "searxng_url = \"http://localhost:8888\"");
    Alcotest.(check bool)
      "the table after it is still there"
      true
      (contains written "[turn]\n# unrelated to search");
    let { Web_search_setup.settings; _ } = observe path in
    Alcotest.(check (option int))
      "the one key that was asked for changed" (Some 30)
      settings.Web_search_setup.timeout_sec)

let test_the_same_change_twice_writes_the_same_file () =
  with_config with_section (fun path ->
    let changes =
      [ Web_search_setup.Set_provider_order
          (providers Web_search_provider.Brave [ Web_search_provider.Searxng ])
      ; Web_search_setup.Set_cache_ttl_sec 300.0
      ]
    in
    applied path changes;
    let once = read path in
    applied path changes;
    Alcotest.(check string) "a second run is a no-op on the bytes" once (read path))

let test_a_provider_list_is_written_in_order_without_repeats () =
  with_config runtime_base (fun path ->
    applied
      path
      [ Web_search_setup.Set_provider_order
          (providers
             Web_search_provider.Brave
             Web_search_provider.[ Tavily; Brave; Exa; Tavily ])
      ; Web_search_setup.Set_fallbacks (providers Web_search_provider.Ollama [])
      ];
    let { Web_search_setup.settings; _ } = observe path in
    Alcotest.(check (option string))
      "first mention wins, order kept" (Some "brave,tavily,exa")
      settings.Web_search_setup.provider_order;
    Alcotest.(check (option string))
      "a single provider is a list of one" (Some "ollama")
      settings.Web_search_setup.fallbacks)

let test_a_float_is_written_as_a_float () =
  with_config runtime_base (fun path ->
    applied path [ Web_search_setup.Set_cache_ttl_sec 900.0 ];
    Alcotest.(check bool)
      "the value keeps its decimal point, so the loader does not read an integer"
      true
      (contains (read path) "cache_ttl_sec = 900.0");
    let { Web_search_setup.settings; problems; _ } = observe path in
    Alcotest.(check (option (float 0.0)))
      "cache_ttl_sec" (Some 900.0) settings.Web_search_setup.cache_ttl_sec;
    Alcotest.(check (list string)) "loads" [] problems)

let test_unset_removes_the_key_and_only_that_key () =
  with_config with_section (fun path ->
    applied path [ Web_search_setup.Unset Web_search_setup.Provider ];
    let written = read path in
    Alcotest.(check bool)
      "the provider line is gone" false (contains written "provider = \"searxng\"");
    Alcotest.(check bool)
      "the searxng_url line stays" true (contains written "searxng_url =");
    let { Web_search_setup.settings; _ } = observe path in
    Alcotest.(check (option string))
      "provider reads as unset" None settings.Web_search_setup.provider)

(* ---- refusals write nothing ---- *)

let refused_and_untouched ~label contents changes =
  with_config contents (fun path ->
    match apply path changes with
    | Ok _revision -> Alcotest.failf "%s: must not be written" label
    | Error _ -> Alcotest.(check string) (label ^ ": the file is untouched") contents (read path))

let test_a_timeout_outside_the_range_is_not_written () =
  refused_and_untouched ~label:"zero" with_section [ Web_search_setup.Set_timeout_sec 0 ];
  refused_and_untouched ~label:"above the cap" with_section [ Web_search_setup.Set_timeout_sec 61 ]

let test_a_negative_ttl_is_not_written () =
  refused_and_untouched ~label:"negative ttl" with_section
    [ Web_search_setup.Set_cache_ttl_sec (-1.0) ]

let test_the_refusal_names_the_key () =
  with_config with_section (fun path ->
    match apply path [ Web_search_setup.Set_timeout_sec 0 ] with
    | Error (Web_search_setup.Section_invalid message) ->
      Alcotest.(check bool)
        "the sentence names the key" true (contains message "web_search.timeout_sec")
    | Ok _ -> Alcotest.fail "zero seconds must be refused"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

let test_a_searxng_url_the_reader_would_refuse_is_not_written () =
  List.iter
    (fun url ->
       refused_and_untouched ~label:url with_section [ Web_search_setup.Set_searxng_url url ])
    [ ""
    ; "localhost:8888"
    ; "ftp://search.example"
    ; "http://"
    ; "https://user:SECRETPASS6@search.example"
    ];
  with_config with_section (fun path ->
    match apply path [ Web_search_setup.Set_searxng_url "https://user:SECRETPASS6@search.example" ] with
    | Error (Web_search_setup.Section_invalid message) ->
      Alcotest.(check bool)
        "refusal message redacts password"
        false
        (contains message "SECRETPASS6");
      Alcotest.(check bool)
        "refusal message shows redacted authority"
        true
        (contains message "https://[REDACTED]@search.example")
    | Ok _ -> Alcotest.fail "searxng_url with userinfo must be refused"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

(* Credentials are process environment here; a blank value is absent, which is
   how a variable is "unset" from OCaml. The previous value comes back. *)
let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:""))
    f

let test_display_searxng_url_redacts_userinfo () =
  Alcotest.(check string)
    "url without userinfo is unchanged"
    "https://search.example:8443/path?q=a@b"
    (Web_search_setup.display_searxng_url "https://search.example:8443/path?q=a@b");
  Alcotest.(check string)
    "user:password userinfo is redacted"
    "https://[REDACTED]@search.example"
    (Web_search_setup.display_searxng_url "https://user:SECRETPASS6@search.example");
  Alcotest.(check string)
    "user-only userinfo is redacted"
    "http://[REDACTED]@search.example:8888/search"
    (Web_search_setup.display_searxng_url "http://user@search.example:8888/search");
  Alcotest.(check string)
    "scheme-less authority userinfo is redacted"
    "[REDACTED]@search.example:8888"
    (Web_search_setup.display_searxng_url "user:SECRETPASS6@search.example:8888");
  Alcotest.(check string)
    "protocol-relative authority userinfo is redacted"
    "//[REDACTED]@search.example:8888/search"
    (Web_search_setup.display_searxng_url "//user:SECRETPASS6@search.example:8888/search");
  Alcotest.(check string)
    "scheme-less authority userinfo with :// in query is redacted"
    "[REDACTED]@search.example/?next=http://other"
    (Web_search_setup.display_searxng_url
       "user:SECRETPASS6@search.example/?next=http://other");
  Alcotest.(check string)
    "scheme-less url without userinfo keeps @ inside :// query parameter"
    "search.example/?next=http://a@b"
    (Web_search_setup.display_searxng_url "search.example/?next=http://a@b");
  with_env "MASC_SEARXNG_URL" "user:SECRETPASS6@search.example:8888" (fun () ->
    match Env_config_runtime.Tools.searxng_base_url () with
    | Error msg ->
      Alcotest.(check bool)
        "scheme-less env error redacts password"
        false
        (contains msg "SECRETPASS6");
      Alcotest.(check bool)
        "scheme-less env error shows redacted authority"
        true
        (contains msg "[REDACTED]@search.example:8888")
    | Ok url -> Alcotest.failf "expected scheme refusal, got Ok %S" url);
  with_env "MASC_SEARXNG_URL" "http:user:SECRETPASS6@search.example" (fun () ->
    match Env_config_runtime.Tools.searxng_base_url () with
    | Error msg ->
      Alcotest.(check bool)
        "missing-// http env error redacts password"
        false
        (contains msg "SECRETPASS6")
    | Ok url -> Alcotest.failf "expected missing-// refusal, got Ok %S" url)

let test_a_searxng_url_is_written_as_given () =
  with_config runtime_base (fun path ->
    applied path [ Web_search_setup.Set_searxng_url "https://search.example:8443" ];
    let { Web_search_setup.settings; _ } = observe path in
    Alcotest.(check (option string))
      "searxng_url" (Some "https://search.example:8443") settings.Web_search_setup.searxng_url)

let test_two_changes_to_one_key_are_refused () =
  with_config with_section (fun path ->
    match
      apply
        path
        [ Web_search_setup.Set_provider Web_search_provider.Brave
        ; Web_search_setup.Unset Web_search_setup.Provider
        ]
    with
    | Error (Web_search_setup.Conflicting_changes Web_search_setup.Provider) ->
      Alcotest.(check string) "the file is untouched" with_section (read path)
    | Ok _ -> Alcotest.fail "two changes to one key must not be applied"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

let test_a_stale_revision_writes_nothing () =
  with_config with_section (fun path ->
    let stale = (observe path).Web_search_setup.revision in
    let concurrent = with_section ^ "\n# another session was here\n" in
    Out_channel.with_open_bin path (fun out -> output_string out concurrent);
    match
      Web_search_setup.apply
        ~runtime_config_path:path
        ~expected_revision:stale
        [ Web_search_setup.Set_provider Web_search_provider.Exa ]
    with
    | Error Web_search_setup.Configuration_changed ->
      Alcotest.(check string) "the other writer's text is intact" concurrent (read path)
    | Ok _ -> Alcotest.fail "a stale revision must not be applied"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

(* [web_search] spelled as an inline table: a line editor opens a second
   [web_search] table beside it, which the file refuses to load. That has to
   come back as a refusal, not as a half-written file. *)
let test_an_inline_table_is_refused_not_half_written () =
  (* At the root, before any header: after one it would be a key of that table. *)
  let inline = "web_search = { provider = \"brave\" }\n" ^ runtime_base in
  with_config inline (fun path ->
    match apply path [ Web_search_setup.Set_provider Web_search_provider.Tavily ] with
    | Error Web_search_setup.Table_not_reachable ->
      Alcotest.(check string) "the file is untouched" inline (read path)
    | Ok _ -> Alcotest.fail "an inline table must not be written beside"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

(* Dotted keys at the root define the table, and a [web_search] header opened
   after them is invalid TOML 1.0 that Otoml still reads. Without the check the
   file would commit and then fail a strict reader. *)
let test_dotted_keys_at_the_root_are_refused_not_written_beside () =
  let dotted = "web_search.timeout_sec = 20\n" ^ runtime_base in
  with_config dotted (fun path ->
    match apply path [ Web_search_setup.Set_provider Web_search_provider.Brave ] with
    | Error Web_search_setup.Table_not_reachable ->
      Alcotest.(check string) "the file is untouched" dotted (read path)
    | Ok _ -> Alcotest.fail "a header must not be opened beside dotted keys"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

(* A file that is not TOML is unreadable, not an edit that failed: the same
   observe backs the no-option status. *)
let test_a_file_that_does_not_parse_is_unreadable () =
  with_config (runtime_base ^ "\n[web_search\n") (fun path ->
    match Web_search_setup.observe ~runtime_config_path:path with
    | Error (Web_search_setup.Configuration_unavailable _) -> ()
    | Ok _ -> Alcotest.fail "a file with an unclosed header must not observe"
    | Error error -> Alcotest.fail (Web_search_setup.error_message error))

(* ---- the table the writer and the search tool share ---- *)

let test_every_key_is_a_row_the_registry_owns () =
  List.iter
    (fun key ->
       match Keeper_runtime_setting_registry.find_by_toml_key (Web_search_setup.toml_key key) with
       | Some _ -> ()
       | None ->
         Alcotest.failf
           "%s is not a runtime setting the registry names" (Web_search_setup.toml_key key))
    Web_search_setup.all_of_key

(* The registry lists these variables again as documentation rows. Nothing
   derives one from the other, so this is what notices a provider added to one. *)
let test_every_credential_variable_is_a_registry_row () =
  let rows =
    List.map
      (fun (row : Keeper_runtime_setting_registry.setting) ->
         row.Keeper_runtime_setting_registry.env_name)
      Keeper_runtime_setting_registry.all
  in
  List.iter
    (fun provider ->
       List.iter
         (fun name ->
            Alcotest.(check bool)
              (Printf.sprintf "%s (%s) is a registry row" name
                 (Web_search_provider.label provider))
              true
              (List.mem name rows))
         (Web_search_provider.credential_env_names provider))
    Web_search_provider.all

(* SearXNG is the one provider a call reaches without its variable: the reader
   falls back to the default address. The command's warning leans on this. *)
let test_only_searxng_is_called_without_its_credential () =
  List.iter
    (fun provider ->
       Alcotest.(check bool)
         (Web_search_provider.label provider)
         (provider <> Web_search_provider.Searxng)
         (Web_search_provider.needs_credential_to_call provider))
    Web_search_provider.all

let test_labels_round_trip () =
  List.iter
    (fun provider ->
       Alcotest.(check bool)
         (Web_search_provider.label provider ^ " reads back as itself")
         true
         (Web_search_provider.of_label (Web_search_provider.label provider) = Some provider))
    Web_search_provider.all

let test_aliases_and_the_names_that_are_no_provider () =
  Alcotest.(check bool)
    "searx is searxng" true
    (Web_search_provider.of_label " SearX " = Some Web_search_provider.Searxng);
  Alcotest.(check bool)
    "bing is bing_api" true
    (Web_search_provider.of_label "bing" = Some Web_search_provider.Bing_api);
  Alcotest.(check bool)
    "brave-llm-context is brave_llm_context" true
    (Web_search_provider.of_label "brave-llm-context" = Some Web_search_provider.Brave_llm_context);
  List.iter
    (fun raw ->
       Alcotest.(check bool) (Printf.sprintf "%S names no provider" raw) true
         (Web_search_provider.of_label raw = None))
    [ "auto"; ""; "duckduckgo"; "brav" ]

let test_the_default_order_leaves_out_the_grounded_provider () =
  Alcotest.(check (list string))
    "the chain a call starts from, before credentials filter it"
    [ "searxng"; "brave"; "tavily"; "exa"; "bing_api"; "ollama" ]
    (List.map Web_search_provider.label Web_search_provider.default_order)

let test_a_blank_credential_is_absent_and_a_set_one_is_read_trimmed () =
  with_env "TAVILY_API_KEY" "   " (fun () ->
    Alcotest.(check bool)
      "blanks do not admit the provider" false
      (Web_search_provider.has_credentials Web_search_provider.Tavily);
    Unix.putenv "TAVILY_API_KEY" "  tvly-fixture  ";
    Alcotest.(check (option string))
      "the value is what a fetcher sends" (Some "tvly-fixture")
      (Web_search_provider.credential Web_search_provider.Tavily))

let test_either_bing_variable_admits_bing () =
  with_env "BING_SEARCH_API_KEY" "" (fun () ->
    with_env "AZURE_BING_SEARCH_API_KEY" "azure-fixture" (fun () ->
      Alcotest.(check (option string))
        "the second name is read when the first is blank" (Some "azure-fixture")
        (Web_search_provider.credential Web_search_provider.Bing_api)))

let () =
  Alcotest.run
    "web_search_setup"
    [ ( "observe"
      , [ Alcotest.test_case "reads the section" `Quick test_observe_reads_the_section
        ; Alcotest.test_case "a file without the section is unset" `Quick
            test_a_file_without_the_section_observes_as_unset
        ; Alcotest.test_case "a key of the wrong type is reported" `Quick
            test_a_key_of_the_wrong_type_is_reported
        ; Alcotest.test_case "a file that does not parse is unreadable" `Quick
            test_a_file_that_does_not_parse_is_unreadable
        ] )
    ; ( "writes"
      , [ Alcotest.test_case "a new section is appended and nothing else moves" `Quick
            test_a_new_section_is_appended_and_nothing_else_moves
        ; Alcotest.test_case "an edit keeps the notes and the other tables" `Quick
            test_an_edit_keeps_the_notes_and_the_other_tables
        ; Alcotest.test_case "the same change twice writes the same file" `Quick
            test_the_same_change_twice_writes_the_same_file
        ; Alcotest.test_case "a provider list keeps order and drops repeats" `Quick
            test_a_provider_list_is_written_in_order_without_repeats
        ; Alcotest.test_case "a float is written as a float" `Quick
            test_a_float_is_written_as_a_float
        ; Alcotest.test_case "unset removes the key and only that key" `Quick
            test_unset_removes_the_key_and_only_that_key
        ; Alcotest.test_case "a searxng url is written as given" `Quick
            test_a_searxng_url_is_written_as_given
        ] )
    ; ( "refusals write nothing"
      , [ Alcotest.test_case "a timeout outside the range" `Quick
            test_a_timeout_outside_the_range_is_not_written
        ; Alcotest.test_case "a negative ttl" `Quick test_a_negative_ttl_is_not_written
        ; Alcotest.test_case "the refusal names the key" `Quick test_the_refusal_names_the_key
        ; Alcotest.test_case "a searxng url the reader would refuse" `Quick
            test_a_searxng_url_the_reader_would_refuse_is_not_written
        ; Alcotest.test_case "display_searxng_url redacts userinfo" `Quick
            test_display_searxng_url_redacts_userinfo
        ; Alcotest.test_case "two changes to one key" `Quick
            test_two_changes_to_one_key_are_refused
        ; Alcotest.test_case "a stale revision" `Quick test_a_stale_revision_writes_nothing
        ; Alcotest.test_case "an inline table" `Quick
            test_an_inline_table_is_refused_not_half_written
        ; Alcotest.test_case "dotted keys at the root" `Quick
            test_dotted_keys_at_the_root_are_refused_not_written_beside
        ] )
    ; ( "the shared provider table"
      , [ Alcotest.test_case "every key is a registry row" `Quick
            test_every_key_is_a_row_the_registry_owns
        ; Alcotest.test_case "every credential variable is a registry row" `Quick
            test_every_credential_variable_is_a_registry_row
        ; Alcotest.test_case "only searxng is called without its credential" `Quick
            test_only_searxng_is_called_without_its_credential
        ; Alcotest.test_case "labels round trip" `Quick test_labels_round_trip
        ; Alcotest.test_case "aliases and names that are no provider" `Quick
            test_aliases_and_the_names_that_are_no_provider
        ; Alcotest.test_case "the default order leaves out the grounded provider" `Quick
            test_the_default_order_leaves_out_the_grounded_provider
        ; Alcotest.test_case "a blank credential is absent, a set one is trimmed" `Quick
            test_a_blank_credential_is_absent_and_a_set_one_is_read_trimmed
        ; Alcotest.test_case "either bing variable admits bing" `Quick
            test_either_bing_variable_admits_bing
        ] )
    ]
