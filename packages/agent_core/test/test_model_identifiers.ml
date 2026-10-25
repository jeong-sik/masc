(** Exact identifier admission, catalog matching and provider ownership. *)
open Llm_provider

let model_of = Model_identifiers.Model_id.of_string_exn
let same_model left right = Model_identifiers.Model_id.equal (model_of left) (model_of right)

let check_error
    ~of_string
    ~(show : _ -> string)
    ~expected raw =
  match of_string raw with
  | Error message -> Alcotest.(check string) "loader message verbatim" expected message
  | Ok value -> Alcotest.failf "of_string %S should be rejected, got %S" raw (show value)
;;

let test_exact_identity () =
  Alcotest.(check bool) "exact declaration" true
    (same_model "claude-opus-5-5" "claude-opus-5-5");
  Alcotest.(check bool) "ASCII case equality" true
    (same_model "CLAUDE-OPUS-5-5" "claude-opus-5-5");
  Alcotest.(check string) "producer spelling retained" "GLM-5.3"
    (Model_identifiers.Model_id.to_string (model_of "GLM-5.3"))
;;

let test_identity_does_not_infer_variants () =
  List.iter (fun other -> Alcotest.(check bool) "undeclared identity differs" false
      (same_model "claude-opus-5-5" other))
    ["claude-"; "opus-5-5"; "claude-opus-5-5-new";
     "provider/claude-opus-5-5"; "claude-opus-5-5:q4"]
;;

(* Construction-time validation: the TOML loaders' invariants and their
   byte-for-byte messages, exercised through the one public constructor. *)
let test_of_string_rejects_padded_and_empty () =
  let of_string = Model_identifiers.Model_id.of_string in
  let show = Model_identifiers.Model_id.to_string in
  check_error ~of_string ~show
    ~expected:"model_id must not be empty" "";
  check_error ~of_string ~show
    ~expected:"model_id must not have leading or trailing whitespace"
    " claude-opus-5-5";
  check_error ~of_string ~show
    ~expected:"model_id must not have leading or trailing whitespace"
    "claude-opus-5-5\t"
;;

(* One rule across the three modules: same rejection, same case folding,
   different labels. *)
module type STRINGY = sig
  type t

  val of_string : string -> (t, string) result
  val equal : t -> t -> bool
  val to_string : t -> string
end

let test_two_modules_share_one_rule () =
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
    [ (module Api_name : STRINGY), "api_name must not be empty"
    ; (module Model_id : STRINGY), "model_id must not be empty" ]
;;

(* Catalog lookup path: the row keeps its declared spelling; comparison folds
   ASCII case. A padded model id never reaches either lookup: the opaque
   constructor refuses it, so the lookups take a parsed id and a padded query
   cannot become a catalog miss. [lookup_for_provider] still normalizes its
   separate provider-name input. *)
let test_lookup_folds_case_and_rejects_padding () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers lookup case properties"
  in
  (match Model_catalog.lookup catalog (Model_identifiers.Model_id.of_string_exn "CLAUDE-OPUS-5-5") with
   | None -> Alcotest.fail "case-different query must still find its row"
   | Some (entry : Model_catalog.model_entry) ->
     Alcotest.(check string) "row bytes come back as declared" "claude-opus-5-5"
       (Llm_provider.Model_identifiers.Model_id.to_string entry.model_id));
  Alcotest.(check bool) "padded query is not a model id" true
    (Result.is_error (Model_identifiers.Model_id.of_string "  gpt-5.6-sol\t"));
  (match
     Model_catalog.lookup_for_provider
       catalog
       ~provider_name:"openai-responses"
       ~model_id:(Model_identifiers.Model_id.of_string_exn "GPT-5.6-TERRA")
   with
   | None -> Alcotest.fail "provider-scoped query must fold the model_id case"
   | Some entry ->
     Alcotest.(check string) "provider-scoped row found through case" "gpt-5.6-terra"
       (Llm_provider.Model_identifiers.Model_id.to_string entry.model_id));
  Alcotest.(check bool) "provider-scoped padded query is not a model id" true
    (Result.is_error (Model_identifiers.Model_id.of_string "  GPT-5.6-TERRA\t"))
;;

(* A valid id that no row prefixes is a miss ([None]); an empty query is not an
   id at all, so it is the constructor's error rather than a miss. *)
let test_lookup_misses_stay_misses () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers lookup misses"
  in
  Alcotest.(check bool) "query no row prefixes" true
    (Option.is_none
       (Model_catalog.lookup catalog (Model_identifiers.Model_id.of_string_exn "xclaude-opus-5-5")));
  Alcotest.(check bool) "empty query is not a model id" true
    (Result.is_error (Model_identifiers.Model_id.of_string ""))
;;

(* #37074: ollama.com serves "deepseek-v4.1-flash" under both the bare name
   and a ":cloud" suffix, but the catalog carried only the bare row while
   [lookup_for_provider] (and, separately,
   [Exact_output_catalog_binding.resolve_exact]) compare model_id with exact
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
  let expect_row ~model_id ~expected_model_id =
    match
      Model_catalog.lookup_for_provider
        catalog
        ~provider_name:"ollama_cloud"
        ~model_id:(Model_identifiers.Model_id.of_string_exn model_id)
    with
    | None -> Alcotest.failf "ollama_cloud/%s should resolve" model_id
    | Some (entry : Model_catalog.model_entry) ->
      Alcotest.(check string)
        (model_id ^ " resolves to its own row")
        expected_model_id
        (Model_identifiers.Model_id.to_string entry.model_id)
  in
  expect_row ~model_id:"deepseek-v4.1-flash" ~expected_model_id:"deepseek-v4.1-flash";
  expect_row
    ~model_id:"deepseek-v4.1-flash:cloud"
    ~expected_model_id:"deepseek-v4.1-flash:cloud"
;;

(* Two identifiers have equal keys exactly when their bytes are equal once
   ASCII letters are folded to lower case and nothing else is changed: the
   rule [equal] states, spelled here with the standard library.  A row id and
   a requested model id compare by the same rule, and a key reads as the
   folded bytes. *)
let test_equality_key_folds_ascii_case_only () =
  let cases =
    [ "claude-opus-5-5"; "CLAUDE-OPUS-5-5"; "Claude-Opus-5-5"; "gpt-5.6-terra"
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
                 (Model_identifiers.Model_id.equality_key (model_of a))
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
                 (Model_identifiers.Model_id.to_string entry.model_id))
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
       let id = Model_identifiers.Model_id.to_string entry.model_id in
       List.iter
         (fun (provider_name, model_id) ->
            let label = Printf.sprintf "%s / %s" provider_name model_id in
            match
              ( Model_catalog.lookup_for_provider catalog ~provider_name
                  ~model_id:(Model_identifiers.Model_id.of_string_exn model_id)
              , scan_scoped_rows rows ~provider_name ~model_id )
            with
            | Some found, Some expected ->
              Alcotest.(check bool) (label ^ " answers with the scanned row") true
                (found == expected)
            | Some _, None -> Alcotest.failf "%s: the index found a row the scan does not" label
            | None, _ -> Alcotest.failf "%s: the row's own provider and id miss" label)
         [ provider, id; String.uppercase_ascii provider, String.uppercase_ascii id ])
    scoped;
  match scoped with
  | [] -> Alcotest.fail "the catalog has no row that names a provider"
  | (provider, _) :: _ ->
    (match
       Model_catalog.lookup_for_provider catalog ~provider_name:provider
         ~model_id:(Model_identifiers.Model_id.of_string_exn "no-row-declares-this-model")
     with
     | None -> ()
     | Some _ -> Alcotest.fail "a model id no row declares must miss")
;;

(* Every catalog enters through the strict TOML constructor. *)
let test_scoped_lookup_rejects_duplicate_rows () =
  let row model provider context =
    Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = %S\nmax_context_tokens = %d\n"
      model provider context
  in
  List.iter
    (fun (first, second) ->
       Alcotest.(check bool) "duplicate exact identity rejected" true
         (Result.is_error
            (Model_catalog.of_toml_string ~source:"duplicate scoped rows"
               (first ^ second))))
    [ row "Fold-Model" "provider-a" 10, row "Fold-Model" "provider-a" 1
    ; row "Fold-Model" "provider-a" 1, row "Fold-Model" "provider-a" 10
    ; row "Fold-Model" "provider-a" 10, row "fold-model" "PROVIDER-A" 1
    ]
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
  match Model_identifiers.Model_id.of_string model_id with
  | Error detail -> Error detail
  | Ok model_id ->
    (match Model_catalog.lookup_for_provider catalog ~provider_name ~model_id with
     | Some (entry : Model_catalog.model_entry) ->
       Ok (entry.provider_name, entry.max_context_tokens)
     | None -> Error "no such row")
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
       model_id = \"Fixture-Model-ID\"\n\
       provider_name = \"provider-a\"\n\
       max_context_tokens = 1\n\
       \n\
       [[models]]\n\
       model_id = \"other-model\"\n\
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
       auth = \"none\"\n\
       \n\
       [[models]]\n\
       model_id = \"alias-model\"\n\
       provider_name = \"alias-fixture\"\n\
       max_context_tokens = 1\n\
       \n\
       [[models]]\n\
       model_id = \"verbatim-model\"\n\
       provider_name = \"alias-fixture\"\n\
       max_context_tokens = 2\n\
       \n\
       [[models]]\n\
       model_id = \"verbatim-model\"\n\
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
  check "an alias label is folded before its own rows are asked"
    ~provider_name:" Alias-Fixture-Old " ~model_id:"VERBATIM-MODEL"
    (Ok (Some "alias-fixture-old", Some 3));
  check "the canonical label keeps its own row" ~provider_name:"alias-fixture"
    ~model_id:"verbatim-model" (Ok (Some "alias-fixture", Some 2));
  check "an id neither label declares misses" ~provider_name:"alias-fixture-old"
    ~model_id:"no-row-declares-this-model" (Error "no such row")
;;

(* Two rows under one provider whose ids differ only in case would share one
   slot of the index, and the second would never answer: the loader refuses
   the catalog and names the second row. *)
let test_the_loader_refuses_rows_that_fold_to_one_id () =
  match
    Model_catalog.of_toml_string ~source:"rows that fold to one id"
      "[[models]]\n\
       model_id = \"Dup-Model\"\n\
       provider_name = \"provider-a\"\n\
       \n\
       [[models]]\n\
       model_id = \"dup-model\"\n\
       provider_name = \"provider-a\"\n"
  with
  | Ok _ -> Alcotest.fail "a catalog with two rows that fold to one id loaded"
  | Error message ->
    Alcotest.(check string) "the loader names the second row"
      "model catalog declares model row \"dup-model\" for provider \"provider-a\" twice"
      message
;;

(* Binding and enumeration must read the rows owned by their catalog. *)
let test_binding_and_enumeration_retain_catalog_owned_rows () =
  let catalog context =
    catalog_of_toml ~source:"binding owned rows"
      (Printf.sprintf {|[[providers]]
id = "owner"
kind = "anthropic"
base_url = "https://example.invalid"
request_path = "/v1/messages"
auth = "none"
[[models]]
model_id = "Fold-Model"
provider_name = "owner"
max_context_tokens = %d
|} context)
  in
  let first = catalog 1 in
  let second = catalog 2 in
  List.iter (fun (catalog, context) ->
    match Exact_output_catalog_binding.resolve_exact
        ~catalog ~provider_ref:"owner" ~model_id:"fold-model" with
    | Error _ -> Alcotest.fail "the declared exact model must bind"
    | Ok (provider, model) ->
      Alcotest.(check (option int)) "binding uses this catalog's capability row"
        (Some context) model.max_context_tokens;
      let visible = Model_catalog.model_entries_for_provider catalog
          ~provider:(Model_catalog.Declared_provider "owner") in
      Alcotest.(check bool) "binding and enumeration share the original row" true
        (match visible with [row] -> row == model | _ -> false);
      Alcotest.(check bool) "binding retains this catalog's provider" true
        (match Model_catalog.provider_entries catalog with
         | [row] -> row == provider | _ -> false);
      Alcotest.(check string) "case-folded matching preserves declared wire bytes"
        "Fold-Model" (Model_identifiers.Model_id.to_string model.model_id))
    [first, 1; second, 2; first, 1]
;;

let test_exact_lookup_and_ownership_do_not_expand_names () =
  let owner = {|[[providers]]
id = "owner"
aliases = ["owner-alias"]
kind = "anthropic"
base_url = "https://example.invalid"
request_path = "/v1/messages"
auth = "none"
serves_bare_models = ["family"]
|} in
  let broad = {|[[models]]
model_id = "family"
supports_tools = true
|} in
  let specific = {|[[models]]
model_id = "family-v1"
supports_tools = false
suggested_clients = ["codex"]
|} in
  List.iter (fun declarations ->
    let catalog = catalog_of_toml ~source:"exact catalog identity" (owner ^ declarations) in
    let lookup raw = Model_catalog.lookup catalog (model_of raw) in
    (match lookup "FAMILY-V1" with
     | Some row -> Alcotest.(check (option bool)) "exact row owns its policy" (Some false) row.supports_tools
     | None -> Alcotest.fail "casefold exact row missing");
    List.iter (fun raw -> Alcotest.(check bool) "undeclared name has no inherited row" true
      (Option.is_none (lookup raw)))
      ["family-v2"; "family-v1:q4"; "owner/family"; "owner.family"; "owner:family"];
    let permitted raw = Model_catalog.lookup_model_for_provider catalog
      ~provider:(Declared_provider "owner-alias") ~model_id:(model_of raw) in
    Alcotest.(check bool) "declared alias retains exact permission" true (Option.is_some (permitted "FAMILY"));
    Alcotest.(check bool) "a declared model does not inherit provider permission" true
      (Option.is_none (permitted "family-v1"));
    let row = match lookup "family-v1" with
      | Some row -> row | None -> Alcotest.fail "declared row absent" in
    Alcotest.(check bool) "suggestion metadata remains explicit" true
      (row.suggested_clients = [Model_catalog.Codex]);
    let visible = Model_catalog.model_entries_for_provider catalog
      ~provider:(Declared_provider "owner-alias") in
    Alcotest.(check (list string)) "enumeration and lookup share exact ownership" ["family"]
      (List.map (fun (row : Model_catalog.model_entry) -> Model_identifiers.Model_id.to_string row.model_id) visible))
    [broad ^ specific; specific ^ broad]
;;

let test_retired_prefix_keys_and_invalid_client_tags_are_rejected () =
  List.iter (fun contents -> Alcotest.(check bool) "invalid/legacy declaration rejected" true
    (Result.is_error (Model_catalog.of_toml_string ~source:"exact catalog invalid" contents)))
    [ "[[models]]\nid_prefix = \"legacy\"\n"
    ; "[[models]]\nmodel_id = \"m\"\nsuggested_clients = [\"unknown\"]\n"
    ; "[[models]]\nmodel_id = \"m\"\nsuggested_clients = [\"codex\", \"codex\"]\n"
    ; "[[providers]]\nid=\"owner\"\nkind=\"anthropic\"\nbase_url=\"https://example.invalid\"\nrequest_path=\"/v1/messages\"\nauth=\"none\"\nserves_bare_rows=[\"family\"]\n"
    ]
;;

let () =
  Alcotest.run "model_identifiers"
    [ ( "exact catalog authority"
      , [ Alcotest.test_case "lookup and provider permission do not expand" `Quick test_exact_lookup_and_ownership_do_not_expand_names
        ; Alcotest.test_case "legacy keys and invalid suggestions rejected" `Quick test_retired_prefix_keys_and_invalid_client_tags_are_rejected
        ] )
    ; ( "Model_id exact equality"
      , [ Alcotest.test_case "exact and casefold" `Quick test_exact_identity
        ; Alcotest.test_case "variants are distinct" `Quick test_identity_does_not_infer_variants ] )
    ; ( "Model_id.of_string properties"
      , [ Alcotest.test_case "rejects_padded_and_empty" `Quick test_of_string_rejects_padded_and_empty
        ; Alcotest.test_case "two_modules_share_one_rule" `Quick test_two_modules_share_one_rule ] )
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
        ; Alcotest.test_case "scoped_lookup_rejects_duplicate_rows" `Quick
            test_scoped_lookup_rejects_duplicate_rows
        ; Alcotest.test_case "scoped_lookup_folds_row_ids_and_keeps_providers_apart" `Quick
            test_scoped_lookup_folds_row_ids_and_keeps_providers_apart
        ; Alcotest.test_case "scoped_lookup_retries_under_the_canonical_provider" `Quick
            test_scoped_lookup_retries_under_the_canonical_provider
        ; Alcotest.test_case "the_loader_refuses_rows_that_fold_to_one_id" `Quick
            test_the_loader_refuses_rows_that_fold_to_one_id
        ; Alcotest.test_case "binding_and_enumeration_retain_catalog_owned_rows" `Quick
            test_binding_and_enumeration_retain_catalog_owned_rows ] ) ]
