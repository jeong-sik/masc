(** Unit tests for the constitution article vocabulary (RFC-0442). *)

open Masc.World_constitution_types
module Wire = Masc.World_constitution_wire

let fail_empty where = Alcotest.failf "%s: unexpected empty list" where

let contains ~sub s =
  let n = String.length s and m = String.length sub in
  let rec scan i = i + m <= n && (String.equal (String.sub s i m) sub || scan (i + 1)) in
  m = 0 || scan 0

let ne_list where items =
  match Non_empty.of_list items with
  | Ok value -> value
  | Error `Empty -> fail_empty where

let sample_evidence () =
  ne_list "evidence" [ { uri = "p-0123456789abcdef"; sha256 = None } ]

let sample_ratifiers () = ne_list "ratifiers" [ "alpha"; "beta" ]

let article ?(text = "cite the ledger row, not the frame") ?state () =
  let state =
    match state with
    | Some state -> state
    | None -> Proposed { post_id = "p-0123456789abcdef" }
  in
  match
    make ~id:(Article_id.generate ()) ~text ~evidence:(sample_evidence ())
      ~proposer:"lane-smith" ~state ~last_cited_at:None
  with
  | Ok article -> article
  | Error invalid -> Alcotest.failf "article rejected: %s" (invalid_to_string invalid)

(* {1 Identity} *)

let test_article_id_accepts_only_minted_shape () =
  let minted = Article_id.generate () in
  (match Article_id.of_string (Article_id.to_string minted) with
   | Ok parsed ->
     Alcotest.(check bool)
       "a minted id parses back" true
       (Article_id.equal parsed minted)
   | Error detail -> Alcotest.failf "minted id refused: %s" detail);
  let refused =
    [ "a-placeholder"; "ARTICLE_ONE"; ""; "a-"; "p-0123456789abcdef" ]
  in
  List.iter
    (fun candidate ->
      match Article_id.of_string candidate with
      | Ok _ -> Alcotest.failf "hand-written id %S was accepted" candidate
      | Error _ -> ())
    refused

let test_non_empty_rejects_the_empty_list () =
  (match Non_empty.of_list ([] : string list) with
   | Ok _ -> Alcotest.fail "empty list was accepted"
   | Error `Empty -> ());
  Alcotest.(check int) "length counts head and tail" 2
    (Non_empty.length (sample_ratifiers ()))

(* {1 Construction} *)

let test_make_rejects_unrenderable_articles () =
  let attempt ~text ~proposer ~evidence =
    make ~id:(Article_id.generate ()) ~text ~evidence ~proposer
      ~state:(Proposed { post_id = "p-1" })
      ~last_cited_at:None
  in
  (match
     attempt ~text:"   " ~proposer:"lane-smith" ~evidence:(sample_evidence ())
   with
   | Error Empty_text -> ()
   | Ok _ -> Alcotest.fail "blank text was accepted"
   | Error other ->
     Alcotest.failf "wrong rejection: %s" (invalid_to_string other));
  (match attempt ~text:"a norm" ~proposer:"" ~evidence:(sample_evidence ()) with
   | Error Empty_proposer -> ()
   | Ok _ -> Alcotest.fail "blank proposer was accepted"
   | Error other ->
     Alcotest.failf "wrong rejection: %s" (invalid_to_string other));
  let blank_uri =
    ne_list "evidence"
      [ { uri = "p-1"; sha256 = None }; { uri = " "; sha256 = None } ]
  in
  match attempt ~text:"a norm" ~proposer:"lane-smith" ~evidence:blank_uri with
  | Error (Empty_evidence_uri { index }) ->
    Alcotest.(check int) "names the offending row" 1 index
  | Ok _ -> Alcotest.fail "blank evidence uri was accepted"
  | Error other -> Alcotest.failf "wrong rejection: %s" (invalid_to_string other)

let test_cite_only_moves_forward () =
  let base = article () in
  let cited = cite base ~at:100.0 in
  Alcotest.(check (option (float 0.001)))
    "first citation lands" (Some 100.0) cited.last_cited_at;
  let replayed = cite cited ~at:50.0 in
  Alcotest.(check (option (float 0.001)))
    "an out-of-order replay cannot make it staler" (Some 100.0)
    replayed.last_cited_at;
  let later = cite cited ~at:150.0 in
  Alcotest.(check (option (float 0.001)))
    "a later citation moves forward" (Some 150.0) later.last_cited_at

(* {1 Transitions} *)

let state_name = function
  | Proposed _ -> "proposed"
  | Ratified _ -> "ratified"
  | Superseded _ -> "superseded"
  | Repealed _ -> "repealed"

let test_transition_matrix_is_exhaustive () =
  let states =
    [ Proposed { post_id = "p-1" }
    ; Ratified { at = 10.0; ratifiers = sample_ratifiers () }
    ; Superseded { by = Article_id.generate (); at = 20.0 }
    ; Repealed { at = 30.0; post_id = "p-2" }
    ]
  in
  let legal =
    [ "proposed", "ratified"
    ; "proposed", "repealed"
    ; "ratified", "superseded"
    ; "ratified", "repealed"
    ]
  in
  let checked = ref 0 in
  List.iter
    (fun from_ ->
      List.iter
        (fun to_ ->
          incr checked;
          let pair = state_name from_, state_name to_ in
          let expected_legal =
            List.exists
              (fun (a, b) ->
                String.equal a (fst pair) && String.equal b (snd pair))
              legal
          in
          let subject = article ~state:from_ () in
          match transition subject ~to_, expected_legal with
          | Ok moved, true ->
            Alcotest.(check string)
              (Printf.sprintf "%s -> %s lands in the target state" (fst pair)
                 (snd pair))
              (snd pair) (state_name moved.state)
          | Error _, false -> ()
          | Ok _, false ->
            Alcotest.failf "%s -> %s was accepted" (fst pair) (snd pair)
          | Error error, true ->
            Alcotest.failf "%s -> %s was refused: %s" (fst pair) (snd pair)
              (transition_error_to_string error))
        states)
    states;
  Alcotest.(check int) "every ordered pair is answered" 16 !checked

(* {1 Wire} *)

let roundtrip name state =
  let subject = cite (article ~state ()) ~at:42.0 in
  match Wire.of_json (Wire.to_json subject) with
  | Error error ->
    Alcotest.failf "%s did not decode: %s" name (Wire.decode_error_to_string error)
  | Ok decoded ->
    Alcotest.(check string)
      (name ^ ": id survives")
      (Article_id.to_string subject.id)
      (Article_id.to_string decoded.id);
    Alcotest.(check string) (name ^ ": text survives") subject.text decoded.text;
    Alcotest.(check string)
      (name ^ ": state survives")
      (state_name subject.state) (state_name decoded.state);
    Alcotest.(check (option (float 0.001)))
      (name ^ ": citation survives")
      subject.last_cited_at decoded.last_cited_at

let test_wire_roundtrip_every_state () =
  roundtrip "proposed" (Proposed { post_id = "p-1" });
  roundtrip "ratified" (Ratified { at = 10.0; ratifiers = sample_ratifiers () });
  roundtrip "superseded" (Superseded { by = Article_id.generate (); at = 20.0 });
  roundtrip "repealed" (Repealed { at = 30.0; post_id = "p-2" })

let test_wire_field_names_are_fixed () =
  let json = Wire.to_json (article ()) in
  let keys =
    match json with
    | `Assoc fields -> List.map fst fields
    | _ -> Alcotest.fail "an article does not encode as an object"
  in
  let expected =
    [ "id"; "text"; "evidence"; "proposer"; "state"; "last_cited_at" ]
  in
  Alcotest.(check (list string)) "article field names" expected keys

let decode_refuses name raw =
  match Wire.of_json (Yojson.Safe.from_string raw) with
  | Ok _ -> Alcotest.failf "%s was accepted" name
  | Error _ -> ()

let valid_json () = Yojson.Safe.to_string (Wire.to_json (article ()))

let test_wire_rejects_a_broken_schema () =
  let base = valid_json () in
  let with_extra =
    match Yojson.Safe.from_string base with
    | `Assoc fields ->
      Yojson.Safe.to_string (`Assoc (fields @ [ "severity", `String "high" ]))
    | _ -> Alcotest.fail "unexpected encoding"
  in
  decode_refuses "an unknown field" with_extra;
  let duplicated =
    match Yojson.Safe.from_string base with
    | `Assoc fields ->
      Yojson.Safe.to_string (`Assoc (fields @ [ "text", `String "again" ]))
    | _ -> Alcotest.fail "unexpected encoding"
  in
  decode_refuses "a duplicated field" duplicated;
  let dropped =
    match Yojson.Safe.from_string base with
    | `Assoc fields ->
      Yojson.Safe.to_string
        (`Assoc
          (List.filter (fun (key, _) -> not (String.equal key "proposer")) fields))
    | _ -> Alcotest.fail "unexpected encoding"
  in
  decode_refuses "a missing field" dropped;
  let replace key value =
    match Yojson.Safe.from_string base with
    | `Assoc fields ->
      Yojson.Safe.to_string
        (`Assoc
          (List.map
             (fun (k, v) -> if String.equal k key then k, value else k, v)
             fields))
    | _ -> Alcotest.fail "unexpected encoding"
  in
  decode_refuses "an article with no evidence" (replace "evidence" (`List []));
  decode_refuses "a hand-written id" (replace "id" (`String "a-placeholder"));
  decode_refuses "an unknown state kind"
    (replace "state" (`Assoc [ "kind", `String "vetoed" ]));
  decode_refuses "a ratification with no ratifiers"
    (replace "state"
       (`Assoc
         [ "kind", `String "ratified"
         ; "at", `Float 1.0
         ; "ratifiers", `List []
         ]))

let test_decode_error_names_its_path () =
  let base = valid_json () in
  let broken =
    match Yojson.Safe.from_string base with
    | `Assoc fields ->
      Yojson.Safe.to_string
        (`Assoc
          (List.map
             (fun (k, v) ->
               if String.equal k "evidence" then
                 k, `List [ `Assoc [ "uri", `Int 7; "sha256", `Null ] ]
               else k, v)
             fields))
    | _ -> Alcotest.fail "unexpected encoding"
  in
  match Wire.of_json (Yojson.Safe.from_string broken) with
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
          Alcotest.test_case "non-empty rejects the empty list" `Quick
            test_non_empty_rejects_the_empty_list;
        ] );
      ( "construction",
        [ Alcotest.test_case "unrenderable articles are refused" `Quick
            test_make_rejects_unrenderable_articles;
          Alcotest.test_case "citation only moves forward" `Quick
            test_cite_only_moves_forward;
        ] );
      ( "transitions",
        [ Alcotest.test_case "every ordered pair is answered" `Quick
            test_transition_matrix_is_exhaustive;
        ] );
      ( "wire",
        [ Alcotest.test_case "roundtrip every state" `Quick
            test_wire_roundtrip_every_state;
          Alcotest.test_case "field names are fixed" `Quick
            test_wire_field_names_are_fixed;
          Alcotest.test_case "a broken schema is refused" `Quick
            test_wire_rejects_a_broken_schema;
          Alcotest.test_case "a rejection names its path" `Quick
            test_decode_error_names_its_path;
        ] );
    ]
