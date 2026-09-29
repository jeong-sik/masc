(* Identifier boundary — regression suite.  Prefix matching lives inside
   the opaque boundary with the same semantics as [equal]: [of_string]
   stores the outside system's spelling verbatim, [to_string] returns it
   unchanged, and [equal] / [starts_with] fold ASCII case at comparison
   time.  The catalog-lookup cases check that the lookup path folds query
   case while row bytes retain their declared spelling. *)
open Llm_provider

let prefix_of entry = Model_identifiers.Id_prefix.of_string_exn entry

let starts_with ~prefix raw =
  Model_identifiers.Id_prefix.starts_with
    ~prefix:(prefix_of prefix)
    (prefix_of raw)
;;

let matches_model_id ~prefix raw =
  Llm_provider.Model_identifiers.Model_id.starts_with
    ~prefix:(prefix_of prefix)
    (Llm_provider.Model_identifiers.Model_id.of_string_exn raw)
;;

let check_error
    ~of_string
    ~(show : _ -> string)
    ~expected raw =
  match of_string raw with
  | Error message -> Alcotest.(check string) "loader message verbatim" expected message
  | Ok value -> Alcotest.failf "of_string %S should be rejected, got %S" raw (show value)
;;

let test_starts_with_exact () =
  Alcotest.(check bool) "claude- matches exactly" true
    (starts_with ~prefix:"claude-" "claude-opus-5");
  Alcotest.(check bool) "gpt- matches exactly" true
    (starts_with ~prefix:"gpt-" "gpt-5.6-sol");
  Alcotest.(check bool) "unrelated prefix" false
    (starts_with ~prefix:"gpt-" "claude-opus-5")
;;

let test_starts_with_normalization () =
  Alcotest.(check bool) "case-different prefix now matches" true
    (starts_with ~prefix:"CLAUDE-" "claude-opus-5");
  Alcotest.(check bool) "case-different value matches" true
    (starts_with ~prefix:"claude-" "CLAUDE-opus-5");
  Alcotest.(check bool) "catalog prefix matches a typed model id" true
    (matches_model_id ~prefix:"CLAUDE-" "claude-opus-5");
  Alcotest.(check string) "of_string preserves the original spelling"
    "GLM-5.3"
    (Llm_provider.Model_identifiers.Id_prefix.to_string (prefix_of "GLM-5.3"))
;;

let test_starts_with_not_suffix () =
  Alcotest.(check bool) "suffix is not a prefix" false
    (starts_with ~prefix:"opus-5" "claude-opus-5")
;;

(* Construction-time validation: the TOML loaders' invariants and their
   byte-for-byte messages, exercised through the one public constructor. *)
let test_of_string_rejects_padded_and_empty () =
  let of_string = Model_identifiers.Id_prefix.of_string in
  let show = Model_identifiers.Id_prefix.to_string in
  check_error ~of_string ~show
    ~expected:"model entry field \"id_prefix\" must not be empty" "";
  check_error ~of_string ~show
    ~expected:"model entry field \"id_prefix\" must not have leading or trailing whitespace"
    " claude-opus-5";
  check_error ~of_string ~show
    ~expected:"model entry field \"id_prefix\" must not have leading or trailing whitespace"
    "claude-opus-5\t"
;;

(* One rule across the three modules: same rejection, same case folding,
   different labels. *)
module type STRINGY = sig
  type t

  val of_string : string -> (t, string) result
  val equal : t -> t -> bool
  val to_string : t -> string
end

let test_three_modules_share_one_rule () =
  let open Llm_provider.Model_identifiers in
  List.iter
    (fun ((module M : STRINGY), empty_message) ->
       check_error ~of_string:M.of_string ~show:M.to_string ~expected:empty_message "";
       (match M.of_string " padded " with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "padded input must be rejected");
       match M.of_string "AbC-xYz", M.of_string "abc-XYZ" with
       | Ok value, Ok other ->
         Alcotest.(check bool) "case-different bytes compare equal" true (M.equal value other);
         Alcotest.(check string) "to_string preserves outside spelling" "AbC-xYz"
           (M.to_string value)
       | Error message, _ | _, Error message ->
         Alcotest.failf "plain id must parse: %s" message)
    [ (module Id_prefix : STRINGY), "model entry field \"id_prefix\" must not be empty"
    ; (module Api_name : STRINGY), "api_name must not be empty"
    ; (module Model_id : STRINGY), "model_id must not be empty" ]
;;

(* Catalog lookup path: the row keeps its declared spelling; comparison folds
   ASCII case. Both lookup paths reject a padded model id at the opaque
   constructor boundary; [lookup_for_provider] still normalizes its separate
   provider-name input. *)
let test_lookup_folds_case_and_rejects_padding () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers lookup case properties"
  in
  match Model_catalog.lookup catalog "CLAUDE-OPUS-5" with
  | None -> Alcotest.fail "case-different query must still find its row"
  | Some (entry : Model_catalog.model_entry) ->
    Alcotest.(check string) "row bytes come back as declared" "claude-opus-5"
      (Llm_provider.Model_identifiers.Id_prefix.to_string entry.id_prefix);
  Alcotest.(check bool) "padded query is rejected" true
    (Option.is_none (Model_catalog.lookup catalog "  gpt-5.6-sol\t"));
  (match Model_catalog.lookup_result catalog "  gpt-5.6-sol\t" with
   | Error (Model_catalog.Malformed_model_id _) -> ()
   | Error Model_catalog.No_such_row ->
     Alcotest.fail "padded query must not become a valid catalog miss"
   | Ok _ -> Alcotest.fail "padded query must not resolve");
  (match
     Model_catalog.lookup_for_provider
       catalog
       ~provider_name:"openai-responses"
       ~model_id:"GPT-5.6-TERRA"
   with
   | None -> Alcotest.fail "provider-scoped query must fold the model_id case"
   | Some entry ->
     Alcotest.(check string) "provider-scoped row found through case" "gpt-5.6-terra"
       (Llm_provider.Model_identifiers.Id_prefix.to_string entry.id_prefix));
  Alcotest.(check bool) "provider-scoped padded query is rejected" true
    (Option.is_none
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"openai-responses"
          ~model_id:"  GPT-5.6-TERRA\t"));
  match
    Model_catalog.lookup_for_provider_result
      catalog
      ~provider_name:"openai-responses"
      ~model_id:"  GPT-5.6-TERRA\t"
  with
  | Error (Model_catalog.Malformed_model_id _) -> ()
  | Error Model_catalog.No_such_row ->
    Alcotest.fail "provider-scoped padded query must not become a valid catalog miss"
  | Ok _ -> Alcotest.fail "provider-scoped padded query must not resolve"
;;

let test_lookup_misses_stay_misses () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers lookup misses"
  in
  Alcotest.(check bool) "query no row prefixes" true
    (Option.is_none (Model_catalog.lookup catalog "xclaude-opus-5"));
  (match Model_catalog.lookup_result catalog "xclaude-opus-5" with
   | Error Model_catalog.No_such_row -> ()
   | Error (Model_catalog.Malformed_model_id detail) ->
     Alcotest.failf "valid miss was called malformed: %s" detail
   | Ok _ -> Alcotest.fail "valid miss unexpectedly resolved");
  Alcotest.(check bool) "empty query matches nothing" true
    (Option.is_none (Model_catalog.lookup catalog ""));
  match Model_catalog.lookup_result catalog "" with
  | Error (Model_catalog.Malformed_model_id _) -> ()
  | Error Model_catalog.No_such_row ->
    Alcotest.fail "empty query must not become a valid catalog miss"
  | Ok _ -> Alcotest.fail "empty query unexpectedly resolved"
;;

(* #37074: ollama.com serves "deepseek-v4.1-flash" under both the bare name
   and a ":cloud" suffix, but the catalog carried only the bare row while
   [lookup_for_provider] (and, separately,
   [Exact_output_catalog_binding.resolve_exact]) compare id_prefix with exact
   equality, never a prefix -- so a deployment whose runtime binding named
   the ":cloud" spelling resolved to no catalog row and the target was
   excluded from every exact-output lane (librarian_exact, hitl_auto_judge,
   board_attention_exact). models.toml now carries a dedicated ":cloud" row,
   the same shape as the qwen3.5:cloud/qwen3.5:397b split above it in the
   file; this pins that both spellings resolve to their own row. *)
let test_ollama_cloud_deepseek_cloud_suffix_resolves () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers deepseek :cloud suffix (#37074)"
  in
  let expect_row ~model_id ~expected_id_prefix =
    match
      Model_catalog.lookup_for_provider
        catalog
        ~provider_name:"ollama_cloud"
        ~model_id
    with
    | None -> Alcotest.failf "ollama_cloud/%s should resolve" model_id
    | Some (entry : Model_catalog.model_entry) ->
      Alcotest.(check string)
        (model_id ^ " resolves to its own row")
        expected_id_prefix
        (Model_identifiers.Id_prefix.to_string entry.id_prefix)
  in
  expect_row ~model_id:"deepseek-v4.1-flash" ~expected_id_prefix:"deepseek-v4.1-flash";
  expect_row
    ~model_id:"deepseek-v4.1-flash:cloud"
    ~expected_id_prefix:"deepseek-v4.1-flash:cloud"
;;

(* Two identifiers have equal keys exactly when their bytes are equal once
   ASCII letters are folded to lower case and nothing else is changed: the
   rule [equal] states, spelled here with the standard library.  A row id and
   a requested model id compare by the same rule, and a key reads as the
   folded bytes. *)
let test_equality_key_folds_ascii_case_only () =
  let cases =
    [ "claude-opus-5"; "CLAUDE-OPUS-5"; "Claude-Opus-5"; "gpt-5.6-terra"
    ; "GPT-5.6-TERRA"; "Qwen/Qwen3-Coder-480B"; "qwen/qwen3-coder-480b"
    ; "deepseek-v4.1-flash:cloud"; "\xc3\x84bc"; "\xc3\xa4bc" ]
  in
  let folded_equal a b =
    String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)
  in
  List.iter
    (fun a ->
       let model_a = Model_identifiers.Model_id.of_string_exn a in
       Alcotest.(check string)
         (Printf.sprintf "the key of %S reads as its folded bytes" a)
         (String.lowercase_ascii a)
         (Model_identifiers.Model_id.equality_key model_a :> string);
       List.iter
         (fun b ->
            let model_b = Model_identifiers.Model_id.of_string_exn b in
            let expected = folded_equal a b in
            Alcotest.(check bool)
              (Printf.sprintf "model ids %S and %S have one key" a b)
              expected
              (Model_identifiers.Equality_key.equal
                 (Model_identifiers.Model_id.equality_key model_a)
                 (Model_identifiers.Model_id.equality_key model_b));
            Alcotest.(check bool)
              (Printf.sprintf "model ids %S and %S are equal" a b)
              expected
              (Model_identifiers.Model_id.equal model_a model_b);
            Alcotest.(check bool)
              (Printf.sprintf "row %S and model id %S have one key" a b)
              expected
              (Model_identifiers.Equality_key.equal
                 (Model_identifiers.Id_prefix.equality_key (prefix_of a))
                 (Model_identifiers.Model_id.equality_key model_b)))
         cases)
    cases
;;

(* What the provider-scoped lookup answered before it had an index: the first
   row, in catalog order, whose provider label and id equal the query's once
   ASCII case is folded on both sides and the labels are trimmed. *)
let scan_scoped_rows rows ~provider_name ~model_id =
  let label value = String.lowercase_ascii (String.trim value) in
  List.find_opt
    (fun (entry : Model_catalog.model_entry) ->
       match entry.provider_name with
       | Some declared ->
         String.equal (label declared) (label provider_name)
         && String.equal
              (String.lowercase_ascii
                 (Model_identifiers.Id_prefix.to_string entry.id_prefix))
              (String.lowercase_ascii model_id)
       | None -> false)
    rows
;;

(* For every row of the repository catalog that names a provider, asked by
   that provider and that row's id in either case, the indexed lookup answers
   with the very row a scan of the rows in catalog order finds. *)
let test_scoped_lookup_matches_a_scan_of_the_rows () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers scoped lookup index"
  in
  let rows = Model_catalog.model_entries catalog in
  let scoped =
    List.filter_map
      (fun (entry : Model_catalog.model_entry) ->
         Option.map (fun provider -> provider, entry) entry.provider_name)
      rows
  in
  List.iter
    (fun (provider, (entry : Model_catalog.model_entry)) ->
       let id = Model_identifiers.Id_prefix.to_string entry.id_prefix in
       List.iter
         (fun (provider_name, model_id) ->
            let label = Printf.sprintf "%s / %s" provider_name model_id in
            match
              ( Model_catalog.lookup_for_provider_result catalog ~provider_name ~model_id
              , scan_scoped_rows rows ~provider_name ~model_id )
            with
            | Ok found, Some expected ->
              Alcotest.(check bool) (label ^ " answers with the scanned row") true
                (found == expected)
            | Ok _, None -> Alcotest.failf "%s: the index found a row the scan does not" label
            | Error _, _ -> Alcotest.failf "%s: the row's own provider and id miss" label)
         [ provider, id; String.uppercase_ascii provider, String.uppercase_ascii id ])
    scoped;
  match scoped with
  | [] -> Alcotest.fail "the catalog has no row that names a provider"
  | (provider, _) :: _ ->
    (match
       Model_catalog.lookup_for_provider_result catalog ~provider_name:provider
         ~model_id:"no-row-declares-this-model"
     with
     | Error Model_catalog.No_such_row -> ()
     | Error (Model_catalog.Malformed_model_id detail) -> Alcotest.fail detail
     | Ok _ -> Alcotest.fail "a model id no row declares must miss")
;;

(* Two rows with one provider and one id: the lookup answers with the first,
   as the scan did. A loaded catalog refuses such a pair; a catalog built from
   entries does not. *)
let test_scoped_lookup_answers_with_the_first_of_equal_rows () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers scoped lookup first row"
  in
  match
    List.find_opt
      (fun (entry : Model_catalog.model_entry) -> Option.is_some entry.provider_name)
      (Model_catalog.model_entries catalog)
  with
  | None -> Alcotest.fail "the catalog has no row that names a provider"
  | Some first ->
    let second = { first with max_context_tokens = Some 1 } in
    let provider_name =
      match first.provider_name with
      | Some provider -> provider
      | None -> Alcotest.fail "the chosen row names a provider"
    in
    let model_id = Model_identifiers.Id_prefix.to_string first.id_prefix in
    let answer entries =
      match
        Model_catalog.lookup_for_provider_result
          (Model_catalog.of_model_entries entries) ~provider_name ~model_id
      with
      | Ok entry -> entry
      | Error _ -> Alcotest.fail "the lookup missed a row that names its provider and id"
    in
    Alcotest.(check bool) "the first row answers" true (answer [ first; second ] == first);
    Alcotest.(check bool) "order decides, not the row" true
      (answer [ second; first ] == second);
    (* The row's provider label is trimmed and case-folded like the query's. *)
    let spelled = { first with provider_name = Some (" " ^ String.uppercase_ascii provider_name ^ " ") } in
    Alcotest.(check bool) "a row's provider label is folded as the query's is" true
      (answer [ spelled ] == spelled)
;;

(* A catalog of the given TOML, or the test fails with the loader's message. *)
let catalog_of_toml ~source toml =
  match Model_catalog.of_toml_string ~source toml with
  | Ok catalog -> catalog
  | Error message -> Alcotest.failf "%s: %s" source message
;;

(* Which row a provider-scoped lookup answers with: [Ok] with the row's
   provider label and [max_context_tokens], or the miss. *)
let scoped_answer catalog ~provider_name ~model_id =
  match Model_catalog.lookup_for_provider_result catalog ~provider_name ~model_id with
  | Ok (entry : Model_catalog.model_entry) -> Ok (entry.provider_name, entry.max_context_tokens)
  | Error Model_catalog.No_such_row -> Error "no such row"
  | Error (Model_catalog.Malformed_model_id detail) -> Error detail
;;

let scoped_answer_t =
  Alcotest.(result (pair (option string) (option int)) string)
;;

(* A row id declared with upper-case letters is found by a query in any case,
   and a row answers only for the provider it names, whatever rows other
   providers declare. *)
let test_scoped_lookup_folds_row_ids_and_keeps_providers_apart () =
  let catalog =
    catalog_of_toml ~source:"scoped lookup row ids"
      "[[models]]\n\
       id_prefix = \"Fixture-Model-ID\"\n\
       provider_name = \"provider-a\"\n\
       max_context_tokens = 1\n\
       \n\
       [[models]]\n\
       id_prefix = \"other-model\"\n\
       provider_name = \"provider-b\"\n\
       max_context_tokens = 2\n"
  in
  let check label ~provider_name ~model_id expected =
    Alcotest.check scoped_answer_t label expected
      (scoped_answer catalog ~provider_name ~model_id)
  in
  check "a lower-case query finds an upper-case row id" ~provider_name:"provider-a"
    ~model_id:"fixture-model-id" (Ok (Some "provider-a", Some 1));
  check "the row's own spelling finds it" ~provider_name:"provider-a"
    ~model_id:"Fixture-Model-ID" (Ok (Some "provider-a", Some 1));
  check "an id only another provider declares misses" ~provider_name:"provider-b"
    ~model_id:"fixture-model-id" (Error "no such row");
  check "the other provider's id misses the first" ~provider_name:"provider-a"
    ~model_id:"other-model" (Error "no such row")
;;

(* A label no row names is retried under the provider it is an alias of, and
   only then: a row declared under the alias label itself answers first. *)
let test_scoped_lookup_retries_under_the_canonical_provider () =
  let catalog =
    catalog_of_toml ~source:"scoped lookup provider alias"
      "[[providers]]\n\
       id = \"alias-fixture\"\n\
       aliases = [\"alias-fixture-old\"]\n\
       kind = \"openai_compat\"\n\
       base_url = \"https://alias.example\"\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\
       \n\
       [[models]]\n\
       id_prefix = \"alias-model\"\n\
       provider_name = \"alias-fixture\"\n\
       max_context_tokens = 1\n\
       \n\
       [[models]]\n\
       id_prefix = \"verbatim-model\"\n\
       provider_name = \"alias-fixture\"\n\
       max_context_tokens = 2\n\
       \n\
       [[models]]\n\
       id_prefix = \"verbatim-model\"\n\
       provider_name = \"alias-fixture-old\"\n\
       max_context_tokens = 3\n"
  in
  let check label ~provider_name ~model_id expected =
    Alcotest.check scoped_answer_t label expected
      (scoped_answer catalog ~provider_name ~model_id)
  in
  check "the alias finds the canonical provider's row" ~provider_name:"alias-fixture-old"
    ~model_id:"alias-model" (Ok (Some "alias-fixture", Some 1));
  check "the alias is folded like any label" ~provider_name:" Alias-Fixture-Old "
    ~model_id:"ALIAS-MODEL" (Ok (Some "alias-fixture", Some 1));
  check "a row under the alias label answers before the retry"
    ~provider_name:"alias-fixture-old" ~model_id:"verbatim-model"
    (Ok (Some "alias-fixture-old", Some 3));
  check "the canonical label keeps its own row" ~provider_name:"alias-fixture"
    ~model_id:"verbatim-model" (Ok (Some "alias-fixture", Some 2));
  check "an id neither label declares misses" ~provider_name:"alias-fixture-old"
    ~model_id:"no-row-declares-this-model" (Error "no such row")
;;

let () =
  Alcotest.run "model_identifiers"
    [ ( "Id_prefix.starts_with"
      , [ Alcotest.test_case "exact" `Quick test_starts_with_exact
        ; Alcotest.test_case "normalization" `Quick test_starts_with_normalization
        ; Alcotest.test_case "not_suffix" `Quick test_starts_with_not_suffix ] )
    ; ( "Id_prefix.of_string properties"
      , [ Alcotest.test_case "rejects_padded_and_empty" `Quick test_of_string_rejects_padded_and_empty
        ; Alcotest.test_case "three_modules_share_one_rule" `Quick test_three_modules_share_one_rule ] )
    ; ( "Model_catalog.lookup case properties"
      , [ Alcotest.test_case "query_case_fold_and_padding_rejection" `Quick test_lookup_folds_case_and_rejects_padding
        ; Alcotest.test_case "misses_stay_misses" `Quick test_lookup_misses_stay_misses
        ; Alcotest.test_case "ollama_cloud_deepseek_cloud_suffix_resolves" `Quick
            test_ollama_cloud_deepseek_cloud_suffix_resolves ] )
    ; ( "Model_catalog provider-scoped index"
      , [ Alcotest.test_case "equality_key_folds_ascii_case_only" `Quick
            test_equality_key_folds_ascii_case_only
        ; Alcotest.test_case "scoped_lookup_matches_a_scan_of_the_rows" `Quick
            test_scoped_lookup_matches_a_scan_of_the_rows
        ; Alcotest.test_case "scoped_lookup_answers_with_the_first_of_equal_rows" `Quick
            test_scoped_lookup_answers_with_the_first_of_equal_rows
        ; Alcotest.test_case "scoped_lookup_folds_row_ids_and_keeps_providers_apart" `Quick
            test_scoped_lookup_folds_row_ids_and_keeps_providers_apart
        ; Alcotest.test_case "scoped_lookup_retries_under_the_canonical_provider" `Quick
            test_scoped_lookup_retries_under_the_canonical_provider ] ) ]
