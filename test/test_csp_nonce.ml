(* The CSP nonce every server page draws (#52098): what Csp_nonce makes, and
   that the GraphQL playground and the play page name the nonce of their
   policy on their inline elements and nowhere else. *)

open Alcotest

module Play_page = Server_routes_http_routes_play_page
module Pages = Server_routes_http_pages

let drawn_bytes = 32

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let count ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i found =
    if i + n > m then found
    else if String.sub text i n = sub then at (i + n) (found + 1)
    else at (i + 1) found in
  at 0 0

(* [source] is ['nonce-<value>']; the value is what the browser compares. *)
let value nonce =
  let source = Csp_nonce.source nonce and prefix = "'nonce-" and suffix = "'" in
  if not (String.starts_with ~prefix source && String.ends_with ~suffix source)
  then failf "source %S is not 'nonce-<value>'" source;
  String.sub source (String.length prefix)
    (String.length source - String.length prefix - String.length suffix)

let lowercase_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false

let test_a_draw_is_lowercase_hex () =
  let value = value (Csp_nonce.draw ()) in
  check int "two hex digits per byte" (2 * drawn_bytes) (String.length value);
  check bool "hex digits only, so it ends no source and no attribute" true
    (String.for_all lowercase_hex value)

let test_each_draw_is_its_own () =
  let draws = List.init 64 (fun _ -> value (Csp_nonce.draw ())) in
  check int "no value repeats" (List.length draws)
    (List.length (List.sort_uniq String.compare draws))

let test_the_attribute_carries_the_source_value () =
  let nonce = Csp_nonce.draw () in
  check string "attribute" (Printf.sprintf {|nonce="%s"|} (value nonce))
    (Csp_nonce.attribute nonce)

let test_the_play_page_names_its_nonce () =
  let nonce = Csp_nonce.draw () in
  let value = value nonce and page = Play_page.page ~nonce in
  check bool "the style element is under the nonce" true
    (contains ~sub:(Printf.sprintf {|<style nonce="%s">|} value) page);
  check bool "the script element is under the nonce" true
    (contains ~sub:(Printf.sprintf {|<script nonce="%s" data-retry-ms="|} value) page);
  check int "no other element carries a nonce" 2 (count ~sub:{|nonce="|} page);
  let policy = Play_page.csp_header nonce in
  check bool "the policy runs that script" true
    (contains ~sub:(Printf.sprintf "script-src 'nonce-%s';" value) policy);
  check bool "the policy applies that sheet" true
    (contains ~sub:(Printf.sprintf "style-src 'nonce-%s';" value) policy)

let test_the_playground_names_its_nonce () =
  let nonce = Csp_nonce.draw () in
  let value = value nonce and page = Pages.graphql_playground_html ~nonce in
  check bool "the boot script is under the nonce" true
    (contains ~sub:(Printf.sprintf {|<script nonce="%s">|} value) page);
  check int "no other element carries a nonce" 1 (count ~sub:{|nonce="|} page);
  check bool "the policy runs that script" true
    (contains ~sub:(Printf.sprintf "script-src 'self' 'nonce-%s' 'unsafe-eval';" value)
       (Pages.graphql_csp_header nonce))

let () =
  run "csp nonce"
    [ ( "draw"
      , [ test_case "a draw is 32 bytes of lowercase hex" `Quick test_a_draw_is_lowercase_hex
        ; test_case "each draw is its own" `Quick test_each_draw_is_its_own
        ; test_case "the attribute carries the source value" `Quick
            test_the_attribute_carries_the_source_value
        ] )
    ; ( "pages"
      , [ test_case "the play page names its nonce" `Quick test_the_play_page_names_its_nonce
        ; test_case "the GraphQL playground names its nonce" `Quick
            test_the_playground_names_its_nonce
        ] )
    ]
