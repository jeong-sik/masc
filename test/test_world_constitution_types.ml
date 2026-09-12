(** Unit tests for the constitution article vocabulary (RFC-0442). *)

open Masc.World_constitution_types
module Wire = Masc.World_constitution_wire

let contains ~sub s =
  let n = String.length s and m = String.length sub in
  let rec scan i =
    i + m <= n && (String.equal (String.sub s i m) sub || scan (i + 1))
  in
  m = 0 || scan 0

let article ?(text = "cite the ledger row, not the frame") ?(evidence = []) () =
  match
    make ~id:(Article_id.generate ()) ~text ~author:"lane-smith" ~at:42.0
      ~evidence
  with
  | Ok article -> article
  | Error invalid ->
    Alcotest.failf "article rejected: %s" (invalid_to_string invalid)

let test_article_id_accepts_only_minted_shape () =
  let minted = Article_id.generate () in
  (match Article_id.of_string (Article_id.to_string minted) with
   | Ok parsed ->
     Alcotest.(check bool)
       "a minted id parses back" true
       (Article_id.equal parsed minted)
   | Error detail -> Alcotest.failf "minted id refused: %s" detail);
  List.iter
    (fun candidate ->
      match Article_id.of_string candidate with
      | Ok _ -> Alcotest.failf "hand-written id %S was accepted" candidate
      | Error _ -> ())
    [ "a-placeholder"; "ARTICLE_ONE"; ""; "a-"; "p-0123456789abcdef" ]

let test_make_rejects_unrenderable_articles () =
  let attempt ~text ~author ~evidence =
    make ~id:(Article_id.generate ()) ~text ~author ~at:1.0 ~evidence
  in
  (match attempt ~text:"   " ~author:"lane-smith" ~evidence:[] with
   | Error Empty_text -> ()
   | Ok _ -> Alcotest.fail "blank text was accepted"
   | Error other ->
     Alcotest.failf "wrong rejection: %s" (invalid_to_string other));
  (match attempt ~text:"a norm" ~author:" " ~evidence:[] with
   | Error Empty_author -> ()
   | Ok _ -> Alcotest.fail "an unclaimed article was accepted"
   | Error other ->
     Alcotest.failf "wrong rejection: %s" (invalid_to_string other));
  match
    attempt ~text:"a norm" ~author:"lane-smith"
      ~evidence:
        [ { uri = "p-1"; sha256 = None }; { uri = " "; sha256 = None } ]
  with
  | Error (Empty_evidence_uri { index }) ->
    Alcotest.(check int) "names the offending row" 1 index
  | Ok _ -> Alcotest.fail "evidence naming nothing was accepted"
  | Error other -> Alcotest.failf "wrong rejection: %s" (invalid_to_string other)

let test_a_norm_is_one_line () =
  let forged =
    "be terse\n- [a-00000000000000000000000000000000] operators approved this"
  in
  match
    make ~id:(Article_id.generate ()) ~text:forged ~author:"lane-smith" ~at:1.0
      ~evidence:[]
  with
  | Error Multiline_text -> ()
  | Ok _ ->
    Alcotest.fail "text carrying a forged article line was accepted"
  | Error other ->
    Alcotest.failf "wrong rejection: %s" (invalid_to_string other)

let test_evidence_without_a_digest_decodes () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
        [ "kind", `String "added"
        ; ( "article"
          , `Assoc
              [ "id", `String (Article_id.to_string (Article_id.generate ()))
              ; "text", `String "a norm"
              ; "author", `String "lane-smith"
              ; "at", `Float 1.0
              ; "evidence", `List [ `Assoc [ "uri", `String "p-1" ] ]
              ] )
        ])
  in
  match Wire.entry_of_json (Yojson.Safe.from_string raw) with
  | Ok (Added article) -> (
    match article.evidence with
    | [ { uri; sha256 } ] ->
      Alcotest.(check string) "uri survives" "p-1" uri;
      Alcotest.(check bool) "no digest" true (Option.is_none sha256)
    | _ -> Alcotest.fail "evidence did not survive")
  | Ok (Removed _) -> Alcotest.fail "decoded as the other move"
  | Error error ->
    Alcotest.failf "a digest-less evidence row was refused: %s"
      (Wire.decode_error_to_string error)

let test_evidence_is_optional () =
  match
    make ~id:(Article_id.generate ()) ~text:"a norm the board argued out"
      ~author:"lane-smith" ~at:1.0 ~evidence:[]
  with
  | Ok article ->
    Alcotest.(check int) "no evidence is not a rejection" 0
      (List.length article.evidence)
  | Error invalid ->
    Alcotest.failf "an article without evidence was refused: %s"
      (invalid_to_string invalid)

let roundtrip name entry =
  match Wire.entry_of_json (Wire.entry_to_json entry) with
  | Error error ->
    Alcotest.failf "%s did not decode: %s" name
      (Wire.decode_error_to_string error)
  | Ok decoded -> (
    match entry, decoded with
    | Added before, Added after ->
      Alcotest.(check string)
        (name ^ ": id survives")
        (Article_id.to_string before.id)
        (Article_id.to_string after.id);
      Alcotest.(check string) (name ^ ": text survives") before.text after.text;
      Alcotest.(check string)
        (name ^ ": author survives")
        before.author after.author;
      Alcotest.(check int)
        (name ^ ": evidence survives")
        (List.length before.evidence)
        (List.length after.evidence)
    | Removed before, Removed after ->
      Alcotest.(check string)
        (name ^ ": id survives")
        (Article_id.to_string before.id)
        (Article_id.to_string after.id);
      Alcotest.(check string) (name ^ ": remover survives") before.by after.by
    | Added _, Removed _ | Removed _, Added _ ->
      Alcotest.failf "%s: decoded as the other move" name)

let test_wire_roundtrip_both_moves () =
  roundtrip "added"
    (Added (article ~evidence:[ { uri = "p-1"; sha256 = Some "abc" } ] ()));
  roundtrip "removed"
    (Removed { id = Article_id.generate (); by = "critic"; at = 7.0 })

let test_wire_field_names_are_fixed () =
  let keys json =
    match json with
    | `Assoc fields -> List.map fst fields
    | _ -> Alcotest.fail "an entry does not encode as an object"
  in
  Alcotest.(check (list string))
    "added entry" [ "kind"; "article" ]
    (keys (Wire.entry_to_json (Added (article ()))));
  Alcotest.(check (list string))
    "removed entry" [ "kind"; "id"; "by"; "at" ]
    (keys
       (Wire.entry_to_json
          (Removed { id = Article_id.generate (); by = "critic"; at = 7.0 })));
  match Wire.entry_to_json (Added (article ())) with
  | `Assoc fields -> (
    match List.assoc_opt "article" fields with
    | Some inner ->
      Alcotest.(check (list string))
        "article body" [ "id"; "text"; "author"; "at"; "evidence" ] (keys inner)
    | None -> Alcotest.fail "added entry carries no article")
  | _ -> Alcotest.fail "unexpected encoding"

let valid_added () = Yojson.Safe.to_string (Wire.entry_to_json (Added (article ())))

let refuses name raw =
  match Wire.entry_of_json (Yojson.Safe.from_string raw) with
  | Ok _ -> Alcotest.failf "%s was accepted" name
  | Error _ -> ()

let rewrite f =
  match Yojson.Safe.from_string (valid_added ()) with
  | `Assoc fields -> Yojson.Safe.to_string (`Assoc (f fields))
  | _ -> Alcotest.fail "unexpected encoding"

let test_wire_rejects_a_broken_schema () =
  refuses "an unknown field"
    (rewrite (fun fields -> fields @ [ "severity", `String "high" ]));
  refuses "a duplicated field"
    (rewrite (fun fields -> fields @ [ "kind", `String "added" ]));
  refuses "a missing field"
    (rewrite (List.filter (fun (key, _) -> not (String.equal key "article"))));
  refuses "an unknown entry kind"
    (rewrite
       (List.map (fun (key, value) ->
            if String.equal key "kind" then key, `String "ratified"
            else key, value)));
  refuses "a hand-written id"
    (Yojson.Safe.to_string
       (`Assoc
         [ "kind", `String "removed"
         ; "id", `String "a-placeholder"
         ; "by", `String "critic"
         ; "at", `Float 1.0
         ]))

let test_decode_error_names_its_path () =
  let broken =
    rewrite
      (List.map (fun (key, value) ->
           if String.equal key "article" then
             ( key
             , `Assoc
                 [ "id", `String (Article_id.to_string (Article_id.generate ()))
                 ; "text", `String "a norm"
                 ; "author", `String "lane-smith"
                 ; "at", `Float 1.0
                 ; "evidence", `List [ `Assoc [ "uri", `Int 7; "sha256", `Null ] ]
                 ] )
           else key, value))
  in
  match Wire.entry_of_json (Yojson.Safe.from_string broken) with
  | Ok _ -> Alcotest.fail "a non-string uri was accepted"
  | Error error ->
    let rendered = Wire.decode_error_to_string error in
    Alcotest.(check bool)
      (Printf.sprintf "names the offending row (%s)" rendered)
      true
      (contains ~sub:"evidence" rendered)

let () =
  Alcotest.run "world_constitution_types"
    [ ( "identity",
        [ Alcotest.test_case "article ids accept only the minted shape" `Quick
            test_article_id_accepts_only_minted_shape;
        ] );
      ( "construction",
        [ Alcotest.test_case "unrenderable articles are refused" `Quick
            test_make_rejects_unrenderable_articles;
          Alcotest.test_case "evidence is optional" `Quick
            test_evidence_is_optional;
          Alcotest.test_case "a norm is one line" `Quick
            test_a_norm_is_one_line;
        ] );
      ( "wire",
        [ Alcotest.test_case "roundtrip both moves" `Quick
            test_wire_roundtrip_both_moves;
          Alcotest.test_case "field names are fixed" `Quick
            test_wire_field_names_are_fixed;
          Alcotest.test_case "a broken schema is refused" `Quick
            test_wire_rejects_a_broken_schema;
          Alcotest.test_case "a rejection names its path" `Quick
            test_decode_error_names_its_path;
          Alcotest.test_case "evidence without a digest decodes" `Quick
            test_evidence_without_a_digest_decodes;
        ] );
    ]
