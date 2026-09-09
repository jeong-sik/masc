open Alcotest
module Client = Masc_tui_msx_tick

let revision c = String.make 64 c
let reference ?(width = 1) ?(height = 1) revision =
  ["revision", `String revision; "width", `Int width; "height", `Int height]
let inline ?(width = 1) ?(height = 1) revision rgb =
  `Assoc (["kind", `String "inline"; "rgb_base64", `String (Base64.encode_string rgb)]
    @ reference ~width ~height revision)
let retained ?(width = 1) ?(height = 1) revision =
  `Assoc (["kind", `String "retained"] @ reference ~width ~height revision)
let frame ?(width = 1) ?(height = 1) ?(player = "alice") number pixels =
  `Assoc ["loaded", `Bool true; "number", `Int number; "width", `Int width;
    "height", `Int height; "mode", `String "GRAPHIC4";
    "cartridge", `Null; "disk", `String "game.dsk";
    "players", `List [`Assoc ["who", `String player]]; "pixels", pixels]
let auth token = ["Authorization", "Bearer " ^ token; "X-MASC-Agent", "operator"]
let known body = Yojson.Safe.Util.member "known_pixels" (Yojson.Safe.from_string body)
let require = function Ok value -> value | Error e -> fail e
let loaded = function Some frame -> frame | None -> fail "no frame"
let failure = function Error _ -> () | Ok _ -> fail "failure returned a successful frame"
let fetch ?(host = "localhost") ?(port = 8935) ?(headers = auth "a") cache request =
  Client.fetch cache ~host ~port ~headers ~request

let test_retained_metadata () =
  let cache = Client.create () and tag = revision 'a' in
  let initial = fetch cache (fun ~body ->
    check bool "first request has no retained pixels" true (known body = `Null);
    Ok (frame 1 (inline tag "rgb"))) |> require |> loaded in
  let allocated = Gc.allocated_bytes () in
  for number = 2 to 101 do
    let current = fetch cache (fun ~body ->
      check bool "advertise exact pixels" true (known body = `Assoc (reference tag));
      Ok (frame ~player:"bob" number (retained tag))) |> require |> loaded in
    check int "clock is fresh" number current.msx_number;
    check (list string) "players are fresh" ["bob"] current.msx_players;
    check bool "retained pixels reuse immutable decoded bytes" true (current.msx_rgb == initial.msx_rgb)
  done;
  Printf.printf "100 retained MSX tick client responses allocate %.0f bytes (includes test assertions)\n%!"
    (Gc.allocated_bytes () -. allocated);
  let changed = fetch cache (fun ~body:_ ->
    Ok (frame ~width:2 102 (inline ~width:2 (revision 'b') "newrgb"))) |> require |> loaded in
  check int "new geometry" 2 changed.msx_width;
  check string "new pixels" "newrgb" changed.msx_rgb;
  let repeated = fetch cache (fun ~body ->
    check bool "new reference advertised" true
      (known body = `Assoc (reference ~width:2 (revision 'b')));
    Ok (frame ~width:2 103 (retained ~width:2 (revision 'b')))) |> require |> loaded in
  check bool "changed pixels are then retained" true (changed.msx_rgb == repeated.msx_rgb);
  check bool "ejection clears display" true
    ((fetch cache (fun ~body:_ -> Ok (`Assoc ["loaded", `Bool false])) |> require) = None);
  failure (fetch cache (fun ~body ->
    check bool "ejection clears advertised pixels" true (known body = `Null);
    Ok (frame 104 (retained tag))))

let test_rejected_responses () =
  let tag = revision 'a' in
  let bad_responses =
    [ Error "HTTP 401"; Error "HTTP 503"; Error "connection closed";
      Ok (`List []); Ok (`Assoc ["loaded", `Bool true]);
      Ok (frame 2 (retained (revision 'b')));
      Ok (frame ~width:2 2 (retained tag));
      Ok (frame 2 (inline tag "too long"));
      Ok (frame 2 (`Assoc (["kind", `String "inline"; "rgb_base64", `String "!"] @ reference tag))) ] in
  List.iter (fun response ->
    let cache = Client.create () in
    ignore (fetch cache (fun ~body:_ -> Ok (frame 1 (inline tag "rgb"))) |> require);
    let calls = ref 0 in
    failure (fetch cache (fun ~body:_ -> incr calls; response));
    check int "failed mutation is never retried" 1 !calls;
    failure (fetch cache (fun ~body ->
      check bool "failure clears cached pixels" true (known body = `Null);
      Ok (frame 3 (retained tag))))) bad_responses;
  failure (fetch (Client.create ()) (fun ~body:_ -> Ok (frame 1 (retained tag))));
  let calls = ref 0 in
  let cancellation = Eio.Cancel.Cancelled Exit in
  let propagated =
    try
      ignore (fetch (Client.create ()) (fun ~body:_ -> incr calls; raise cancellation));
      false
    with Eio.Cancel.Cancelled _ as error -> error == cancellation in
  check bool "cancellation propagates unchanged" true propagated;
  check int "cancelled mutation is never retried" 1 !calls

let test_scope () =
  let cache = Client.create () in
  List.iter (fun (host, port, headers) ->
    ignore (fetch cache ~host ~port ~headers (fun ~body ->
      check bool "different scope never advertises old pixels" true (known body = `Null);
      Ok (frame 1 (inline (revision 'a') "rgb"))) |> require))
    ["host-a", 8935, auth "a"; "host-b", 8935, auth "a";
     "host-b", 8936, auth "a"; "host-b", 8936, auth "b";
     "host-b", 8936, []; "host-a", 8935, auth "a"]

let test_late_response () =
  let cache = Client.create () in
  List.iter (fun older_response ->
    ignore (fetch cache ~headers:(auth "a") (fun ~body:_ ->
      (* No lock may be held across the request callback. A newer request
         completes while this request is awaiting its response. *)
      ignore (fetch cache ~headers:(auth "b") (fun ~body:_ ->
        Ok (frame 2 (inline (revision 'b') "new"))) |> require);
      older_response));
    let current = fetch cache ~headers:(auth "b") (fun ~body ->
      check bool "late completion cannot replace or clear new scope" true
        (known body = `Assoc (reference (revision 'b')));
      Ok (frame 3 (retained (revision 'b')))) |> require |> loaded in
    check string "new pixels survive" "new" current.msx_rgb)
    [Ok (frame 1 (inline (revision 'a') "old")); Error "old request failed"]

let () =
  run "retained MSX tick"
    ["response protocol",
      [test_case "fresh metadata with retained and replaced pixels" `Quick test_retained_metadata;
       test_case "malformed or failed responses never retry or resurrect" `Quick test_rejected_responses;
       test_case "server and credential scope" `Quick test_scope;
       test_case "late responses cannot republish old pixels" `Quick test_late_response]]
