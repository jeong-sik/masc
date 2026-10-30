(** Record grants (RFC operator-quiz §4.5, K3): only an operator-owned
    declaration holds them, and each one is checked whole. *)
open Alcotest
module Records = Masc.Lane_addon_records

let binding records = `Assoc [ "sources", `List []; "records", `List records ]
let board ?(visibilities = [ "public"; "unlisted" ]) id =
  `Assoc [ "source_id", `String id; "kind", `String "board"; "visibilities", `List (List.map (fun v -> `String v) visibilities) ]
let repository ?(paths = [ "changelog.d/" ]) id =
  `Assoc [ "source_id", `String id; "kind", `String "repository"; "repository_id", `String "masc"
         ; "paths", `List (List.map (fun p -> `String p) paths) ]

let test_an_operator_declaration_holds_its_grants () =
  match Records.grants ~operator_owned:true (binding [ board "board"; repository "masc-repo" ]) with
  | Ok [ Records.Board { visibilities; _ }; Records.Repository { repository_id; paths; _ } ] ->
    check int "two visibilities" 2 (List.length visibilities);
    check string "the repository" "masc" repository_id;
    check (list string) "its paths" [ "changelog.d/" ] paths
  | Ok _ -> fail "two grants in order expected"
  | Error detail -> fail detail

let test_no_records_key_is_no_grant () =
  check bool "an ordinary binding" true (Records.grants ~operator_owned:false (`Assoc [ "sources", `List [] ]) = Ok [])

let test_only_an_operator_declaration_may_hold_grants () =
  check bool "a manual or Keeper-owned installation is refused" true
    (Result.is_error (Records.grants ~operator_owned:false (binding [ board "board" ])))

let test_each_grant_is_checked_whole () =
  List.iter (fun (label, records) ->
      check bool label true (Result.is_error (Records.grants ~operator_owned:true (binding records))))
    [ "a board grant without visibilities", [ `Assoc [ "source_id", `String "b"; "kind", `String "board" ] ]
    ; "an empty visibilities", [ board ~visibilities:[] "b" ]
    ; "an unknown visibility", [ board ~visibilities:[ "secret" ] "b" ]
    ; "an upper-case visibility", [ board ~visibilities:[ "Public" ] "b" ]
    ; "a kind this host does not have", [ `Assoc [ "source_id", `String "w"; "kind", `String "notepad" ] ]
    ; "the same source_id twice", [ board "x"; repository "x" ]
    ; "a path outside the repository", [ repository ~paths:[ "../secrets" ] "r" ]
    ; "an absolute path", [ repository ~paths:[ "/etc/passwd" ] "r" ]
    ; "an unknown key", [ `Assoc [ "source_id", `String "b"; "kind", `String "board"; "visibilities", `List [ `String "public" ]; "limit", `Int 3 ] ]
    ; "a blank source_id", [ board " " ] ]

let test_paths_cover_directories_and_files () =
  let paths = [ "changelog.d/"; "CHANGELOG.md" ] in
  check bool "a file in a granted directory" true (Records.covers ~paths "changelog.d/44216.md");
  check bool "a granted file" true (Records.covers ~paths "CHANGELOG.md");
  check bool "a file outside" false (Records.covers ~paths "lib/x.ml");
  check bool "a prefix that is not the directory" false (Records.covers ~paths "changelog.dx/a.md");
  check bool "a path that climbs out" false (Records.covers ~paths "changelog.d/../lib/x.ml")

let () =
  run "lane add-on record grants"
    [ ( "grants"
      , [ test_case "an operator declaration holds its grants" `Quick test_an_operator_declaration_holds_its_grants
        ; test_case "no records key is no grant" `Quick test_no_records_key_is_no_grant
        ; test_case "only an operator declaration may hold grants" `Quick test_only_an_operator_declaration_may_hold_grants
        ; test_case "each grant is checked whole" `Quick test_each_grant_is_checked_whole
        ; test_case "paths cover directories and files" `Quick test_paths_cover_directories_and_files ] ) ]
