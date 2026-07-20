(** Property-based tests for the remaining structural text operation.

    Semantic reply classification was deliberately removed: punctuation,
    language endings, and text length must not decide whether model output is
    visible. *)

module Text = Masc.Keeper_text_processing

let token_pool = [ "a"; "Z"; "0"; "é"; "한"; "글"; "🙂" ]

let gen_case =
  let open QCheck.Gen in
  let* tokens = list_size (int_range 0 64) (oneof_list token_pool) in
  let text = String.concat "" tokens in
  let* max_bytes = int_range 0 (String.length text + 4) in
  return (tokens, text, max_bytes)

let print_case (_tokens, text, max_bytes) =
  Printf.sprintf "(%S, max_bytes=%d)" text max_bytes

let expected_prefix ~max_bytes tokens =
  let rec loop bytes rev = function
    | [] -> String.concat "" (List.rev rev)
    | token :: rest ->
      let next_bytes = bytes + String.length token in
      if next_bytes > max_bytes
      then String.concat "" (List.rev rev)
      else loop next_bytes (token :: rev) rest
  in
  loop 0 [] tokens

let prop_truncate_preserves_complete_utf8_tokens =
  QCheck.Test.make ~count:1000
    ~name:"truncate returns the exact complete-token prefix"
    (QCheck.make ~print:print_case gen_case)
    (fun (tokens, text, max_bytes) ->
       let actual, truncated = Text.truncate_utf8_prefix ~max_bytes text in
       let expected = expected_prefix ~max_bytes tokens in
       String.equal actual expected
       && Bool.equal truncated (String.length text > max_bytes))

let () =
  Alcotest.run "pbt_text_processing"
    [ ( "structural_utf8",
        [ QCheck_alcotest.to_alcotest
            prop_truncate_preserves_complete_utf8_tokens
        ] )
    ]
