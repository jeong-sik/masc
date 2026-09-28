(** Stack 1 tests for RFC-0471 collab-core: share links round-trip and
    strictly reject malformed input, the relay envelope packs peer + payload,
    and sealed frames open only with the room key and an intact tag. *)

open Alcotest

let err_to_string = function
  | Collab_link.Missing_separator -> "Missing_separator"
  | Collab_link.Invalid_room_id -> "Invalid_room_id"
  | Collab_link.Invalid_secret -> "Invalid_secret"
  | Collab_link.Invalid_secret_length n ->
    Printf.sprintf "Invalid_secret_length %d" n
  | Collab_link.Missing_fragment -> "Missing_fragment"
;;

let parse_err = testable Fmt.nop (fun a b -> err_to_string a = err_to_string b)
let capability = testable Fmt.nop ( = )
let parse_ok = result (testable Fmt.nop ( = )) parse_err

let parsed_equal a b =
  a.Collab_link.id = b.Collab_link.id
  && a.Collab_link.key = b.Collab_link.key
  && a.Collab_link.capability = b.Collab_link.capability
  && a.Collab_link.write_token = b.Collab_link.write_token
;;

let check_parsed msg expected = function
  | Ok actual when parsed_equal expected actual -> ()
  | Ok _ -> fail (msg ^ ": parsed value mismatch")
  | Error e -> fail (msg ^ ": unexpected " ^ err_to_string e)
;;

let check_parse_error msg expected = function
  | Ok _ -> fail (msg ^ ": expected rejection, parsed")
  | Error actual -> check parse_err msg expected actual
;;

(* A fixed room keeps every vector deterministic; generate is covered by the
   round-trip tests below, which only assert shapes, never values. *)
let room =
  {
    Collab_link.id = String.make 16 'r';
    key = String.make 32 'k';
    write_token = String.make 16 'w';
  }
;;

let test_view_link_roundtrips () =
  let link = Collab_link.format_link room Collab_link.View in
  let expected =
    {
      Collab_link.id = room.id;
      key = room.key;
      capability = Collab_link.View;
      write_token = None;
    }
  in
  check_parsed "view" expected (Collab_link.parse_link link);
  check parse_ok "result testable" (Ok expected) (Collab_link.parse_link link)
;;

let test_control_link_roundtrips () =
  let link = Collab_link.format_link room Collab_link.Control in
  let expected =
    {
      Collab_link.id = room.id;
      key = room.key;
      capability = Collab_link.Control;
      write_token = Some room.write_token;
    }
  in
  check_parsed "control" expected (Collab_link.parse_link link)
;;

let test_generated_room_roundtrips () =
  let fresh = Collab_link.generate () in
  check int "id bytes" 16 (String.length fresh.Collab_link.id);
  check int "key bytes" 32 (String.length fresh.Collab_link.key);
  check int "token bytes" 16 (String.length fresh.Collab_link.write_token);
  let view = Collab_link.format_link fresh Collab_link.View in
  let control = Collab_link.format_link fresh Collab_link.Control in
  (match Collab_link.parse_link view with
   | Ok p ->
     check capability "view cap" Collab_link.View p.Collab_link.capability
   | Error e -> fail ("view: " ^ err_to_string e));
  (match Collab_link.parse_link control with
   | Ok p ->
     check capability "control cap" Collab_link.Control p.Collab_link.capability
   | Error e -> fail ("control: " ^ err_to_string e))
;;

let test_malformed_links_rejected () =
  check_parse_error
    "no dot"
    Collab_link.Missing_separator
    (Collab_link.parse_link "abc");
  check_parse_error
    "two dots"
    Collab_link.Missing_separator
    (Collab_link.parse_link "a.b.c");
  check_parse_error
    "bad room alphabet"
    Collab_link.Invalid_room_id
    (Collab_link.parse_link "***.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
  check_parse_error
    "short room"
    Collab_link.Invalid_room_id
    (Collab_link.parse_link
       "AAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
  check_parse_error
    "bad secret alphabet"
    Collab_link.Invalid_secret
    (Collab_link.parse_link "AAAAAAAAAAAAAAAAAAAAAA.***");
  check_parse_error
    "short secret"
    (Collab_link.Invalid_secret_length 31)
    (Collab_link.parse_link
       ("AAAAAAAAAAAAAAAAAAAAAA."
        ^ Base64.encode_string
            ~pad:false
            ~alphabet:Base64.uri_safe_alphabet
            (String.make 31 'k')));
  check_parse_error
    "in-between secret"
    (Collab_link.Invalid_secret_length 40)
    (Collab_link.parse_link
       ("AAAAAAAAAAAAAAAAAAAAAA."
        ^ Base64.encode_string
            ~pad:false
            ~alphabet:Base64.uri_safe_alphabet
            (String.make 40 'k')))
;;

let test_web_link_roundtrips () =
  let web =
    Collab_link.format_web_link
      ~base:"https://masc.example/r"
      room
      Collab_link.View
  in
  let expected =
    {
      Collab_link.id = room.id;
      key = room.key;
      capability = Collab_link.View;
      write_token = None;
    }
  in
  check_parsed "web view" expected (Collab_link.parse_web_link web);
  check_parse_error
    "no fragment"
    Collab_link.Missing_fragment
    (Collab_link.parse_web_link "https://masc.example/r");
  (* The secret never leaves the fragment: the head alone does not parse. *)
  check_parse_error
    "head only"
    Collab_link.Missing_fragment
    (Collab_link.parse_web_link "https://masc.example/r/")
;;

module Envelope = Collab_envelope

let test_envelope_roundtrips () =
  let payload = "sealed-bytes" in
  let check_peer peer =
    match Envelope.pack ~peer payload with
    | Error _ -> fail ("pack peer " ^ string_of_int peer)
    | Ok bytes ->
      (match Envelope.unpack bytes with
       | Some (peer', payload') ->
         check int "peer" peer peer';
         check string "payload" payload payload'
       | None -> fail "unpack returned None")
  in
  check_peer Envelope.broadcast_peer;
  check_peer 1;
  check_peer Envelope.max_peer
;;

let test_envelope_rejects () =
  (match Envelope.pack ~peer:(-1) "x" with
   | Error (Envelope.Peer_id_out_of_range (-1)) -> ()
   | Error (Envelope.Peer_id_out_of_range n) ->
     fail ("wrong peer in error: " ^ string_of_int n)
   | Ok _ -> fail "negative peer packed");
  (match Envelope.pack ~peer:(Envelope.max_peer + 1) "x" with
   | Error (Envelope.Peer_id_out_of_range _) -> ()
   | Ok _ -> fail "oversize peer packed");
  check
    (option (pair int string))
    "short unpack"
    None
    (Envelope.unpack "abc")
;;

module Seal = Collab_seal

let open_err =
  testable Fmt.nop (fun a b ->
      match a, b with
      | Seal.Sealed_too_short, Seal.Sealed_too_short -> true
      | Seal.Authentication_failed, Seal.Authentication_failed -> true
      | Sealed_too_short, Authentication_failed
      | Authentication_failed, Sealed_too_short -> false)
;;

let key_or_fail secret =
  match Seal.key_of_secret secret with
  | Ok key -> key
  | Error (Seal.Invalid_key_length n) ->
    fail ("key length " ^ string_of_int n)
;;

let test_seal_roundtrips () =
  let key = key_or_fail (String.make 32 'k') in
  let sealed = Seal.seal key "hello keeper" in
  check
    int
    "sealed length"
    (Seal.iv_bytes + String.length "hello keeper" + 16)
    (String.length sealed);
  check
    (result string open_err)
    "open"
    (Ok "hello keeper")
    (Seal.open_sealed key sealed);
  (* Fresh IV per call: the same plaintext seals to different bytes. *)
  check bool "iv differs" true (Seal.seal key "x" <> Seal.seal key "x")
;;

let test_seal_rejects () =
  let key = key_or_fail (String.make 32 'k') in
  let other = key_or_fail (String.make 32 'o') in
  let sealed = Seal.seal key "tamper me" in
  let tampered = Bytes.of_string sealed in
  let last = Bytes.length tampered - 1 in
  let flipped = Char.code (Bytes.get tampered last) lxor 0x01 in
  Bytes.set tampered last (Char.chr flipped);
  check
    (result string open_err)
    "tampered tag"
    (Error Seal.Authentication_failed)
    (Seal.open_sealed key (Bytes.to_string tampered));
  check
    (result string open_err)
    "wrong key"
    (Error Seal.Authentication_failed)
    (Seal.open_sealed other sealed);
  check
    (result string open_err)
    "too short"
    (Error Seal.Sealed_too_short)
    (Seal.open_sealed key (String.make Seal.iv_bytes 'z'));
  (match Seal.key_of_secret (String.make 31 'k') with
   | Error (Seal.Invalid_key_length 31) -> ()
   | Error (Seal.Invalid_key_length n) ->
     fail ("wrong length: " ^ string_of_int n)
   | Ok _ -> fail "short key accepted")
;;

let test_origin_parses_and_renders () =
  let parse = Collab_origin.parse ~schemes:[ "http"; "https"; "ws"; "wss" ] in
  let ok raw expected =
    match parse raw with
    | Error err -> fail (Collab_origin.parse_error_to_string err)
    | Ok origin -> check string ("render " ^ raw) expected (Collab_origin.to_string origin)
  in
  let refused raw =
    check bool ("refuse " ^ raw) true (Result.is_error (parse raw))
  in
  ok "https://relay.test:8443" "https://relay.test:8443";
  ok "wss://relay.test" "wss://relay.test";
  ok "ws://10.0.0.2:1777" "ws://10.0.0.2:1777";
  ok "  https://relay.test/  " "https://relay.test";
  ok "HTTP://relay.test" "http://relay.test";
  ok "http://[::1]:1777" "http://[::1]:1777";
  refused "ftp://relay.test";
  refused "relay.test";
  refused "https://relay.test/r/abc";
  refused "https://relay.test?x=1";
  refused "https://relay.test#frag";
  refused "https://user@relay.test";
  refused "https://relay.test:99999";
  refused "https://relay.test:";
  refused "https://relay.test:abc";
  refused "https://[::1]:abc";
  refused "https://rel ay.test";
  refused "";
  check bool "scheme sets differ" true
    (Result.is_error (Collab_origin.parse ~schemes:[ "http"; "https" ] "wss://relay.test"))
;;

let () =
  run
    "collab-core"
    [
      ( "link",
        [
          test_case "view link roundtrips" `Quick test_view_link_roundtrips;
          test_case
            "control link roundtrips"
            `Quick
            test_control_link_roundtrips;
          test_case
            "generated room roundtrips"
            `Quick
            test_generated_room_roundtrips;
          test_case
            "malformed links rejected"
            `Quick
            test_malformed_links_rejected;
          test_case "web link roundtrips" `Quick test_web_link_roundtrips;
        ] );
      ( "envelope",
        [
          test_case "envelope roundtrips" `Quick test_envelope_roundtrips;
          test_case "envelope rejects" `Quick test_envelope_rejects;
        ] );
      ( "seal",
        [
          test_case "seal roundtrips" `Quick test_seal_roundtrips;
          test_case "seal rejects" `Quick test_seal_rejects;
        ] );
      ( "origin",
        [ test_case "origin parses and renders" `Quick test_origin_parses_and_renders ] );
    ]
;;
