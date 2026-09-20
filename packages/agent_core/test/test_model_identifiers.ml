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
   ASCII case. [lookup] rejects a padded query; [lookup_for_provider] trims
   its query instead — a known divergence tracked in issue #37276, so only
   [lookup]'s padding rule is pinned here. *)
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
  (match
     Model_catalog.lookup_for_provider
       catalog
       ~provider_name:"openai-responses"
       ~model_id:"GPT-5.6-TERRA"
   with
   | None -> Alcotest.fail "provider-scoped query must fold the model_id case"
   | Some entry ->
     Alcotest.(check string) "provider-scoped row found through case" "gpt-5.6-terra"
       (Llm_provider.Model_identifiers.Id_prefix.to_string entry.id_prefix))
;;

let test_lookup_misses_stay_misses () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model_identifiers lookup misses"
  in
  Alcotest.(check bool) "query no row prefixes" true
    (Option.is_none (Model_catalog.lookup catalog "xclaude-opus-5"));
  Alcotest.(check bool) "empty query matches nothing" true
    (Option.is_none (Model_catalog.lookup catalog ""))
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
        ; Alcotest.test_case "misses_stay_misses" `Quick test_lookup_misses_stay_misses ] ) ]
