(** The bytes that carry an image to a terminal.

    Every function here is checked against what the protocol says rather than
    against what this implementation happens to emit: a golden string of its
    own output would pass whatever it did. *)

open Alcotest

let apc = "\x1b_G"
let st = "\x1b\\"

(* Split a run of APC escapes into their bodies. Nothing outside an escape is
   allowed to reach the terminal, so anything between them is a failure the
   caller wants to see. *)
let bodies text =
  let rec loop offset acc =
    match String.index_from_opt text offset '\x1b' with
    | None ->
        if offset < String.length text then
          failf "bytes outside an escape: %S"
            (String.sub text offset (String.length text - offset));
        List.rev acc
    | Some start ->
        if start <> offset then
          failf "bytes before an escape: %S"
            (String.sub text offset (start - offset));
        let after = start + String.length apc in
        if
          String.length text < after
          || not (String.equal (String.sub text start (String.length apc)) apc)
        then failf "escape does not open with APC G: %S" text;
        let rec find_terminator index =
          if index + String.length st > String.length text then
            failf "escape never terminated: %S" text
          else if String.equal (String.sub text index (String.length st)) st
          then index
          else find_terminator (index + 1)
        in
        let stop = find_terminator after in
        loop (stop + String.length st)
          (String.sub text after (stop - after) :: acc)
  in
  loop 0 []
;;

let keys_and_payload body =
  match String.index_opt body ';' with
  | None -> failf "escape body has no payload separator: %S" body
  | Some cut ->
      ( String.split_on_char ',' (String.sub body 0 cut)
      , String.sub body (cut + 1) (String.length body - cut - 1) )
;;

let test_the_payload_is_the_file () =
  let data = String.init 9000 (fun index -> Char.chr (index mod 256)) in
  let escapes =
    Masc_tui_graphics.place ~data { Masc_tui_graphics.columns = 40; rows = 20 }
  in
  let payload =
    bodies escapes |> List.map (fun body -> snd (keys_and_payload body))
    |> String.concat ""
  in
  match Base64.decode payload with
  | Ok decoded -> check string "arrives byte for byte" data decoded
  | Error (`Msg detail) -> failf "payload is not base64: %s" detail
;;

(* The protocol splits a payload across escapes, and terminals drop an escape
   past a length of their own. Every chunk but the last says m=1 -- more is
   coming -- and the last says m=0, which is what lets the terminal draw. *)
let test_every_chunk_but_the_last_says_more () =
  let data = String.make 20_000 'z' in
  let bodies =
    Masc_tui_graphics.place ~data { Masc_tui_graphics.columns = 4; rows = 2 }
    |> bodies
  in
  if List.length bodies < 2 then
    failf "20 kB was not split: %d escape(s)" (List.length bodies);
  List.iteri
    (fun index body ->
      let keys, _ = keys_and_payload body in
      let last = index = List.length bodies - 1 in
      let expected = if last then "m=0" else "m=1" in
      if not (List.exists (String.equal expected) keys) then
        failf "escape %d of %d does not say %s: %S" (index + 1)
          (List.length bodies) expected body)
    bodies
;;

(* Only the first escape carries the image's keys. A later chunk that repeated
   them would be read as a second image. *)
let test_only_the_first_escape_describes_the_image () =
  let data = String.make 12_000 'q' in
  match
    Masc_tui_graphics.place ~data { Masc_tui_graphics.columns = 9; rows = 3 }
    |> bodies
  with
  | [] -> failf "no escapes"
  | first :: rest ->
      let keys, _ = keys_and_payload first in
      List.iter
        (fun expected ->
          if not (List.exists (String.equal expected) keys) then
            failf "the first escape does not say %s: %S" expected first)
        (* q=2 keeps the terminal from answering a placement. Its reply
           would arrive on stdin and be typed into the composer. *)
        [ "f=100"; "a=T"; "c=9"; "r=3"; "q=2" ];
      List.iteri
        (fun index body ->
          let keys, _ = keys_and_payload body in
          List.iter
            (fun key ->
              if not (String.length key > 2 && String.sub key 0 2 = "m=") then
                failf "continuation %d carries %S, not m= alone" (index + 2) key)
            keys)
        rest
;;

(* [f=100] and [payload_media_type] are one fact said twice: the escape says
   it to the terminal and the name says it to a caller holding bytes. A caller
   that checked the name while the escape said something else would admit a
   format the terminal then drops in silence, since [q=2] means it never
   answers. Pinned rather than derived -- which number means PNG is the
   protocol's to say, not ours. *)
let test_the_named_format_is_the_one_the_escape_asks_for () =
  check string "the name says PNG" "image/png"
    Masc_tui_graphics.payload_media_type;
  match
    Masc_tui_graphics.place ~data:"bytes"
      { Masc_tui_graphics.columns = 4; rows = 2 }
    |> bodies
  with
  | [] -> failf "no escapes"
  | first :: _ ->
      let keys, _ = keys_and_payload first in
      if not (List.exists (String.equal "f=100") keys) then
        failf "the escape does not ask for PNG: %S" first

let test_an_empty_image_places_nothing () =
  check string "no escape at all" ""
    (Masc_tui_graphics.place ~data:"" { Masc_tui_graphics.columns = 1; rows = 1 })
;;

let test_the_query_asks_without_drawing () =
  match bodies Masc_tui_graphics.query with
  | [ body ] ->
      let keys, _ = keys_and_payload body in
      List.iter
        (fun expected ->
          if not (List.exists (String.equal expected) keys) then
            failf "the query does not say %s: %S" expected body)
        [ Printf.sprintf "i=%d" Masc_tui_graphics.query_id; "a=q" ]
  | escapes -> failf "the query is %d escapes, not one" (List.length escapes)
;;

let test_a_reply_is_read_for_what_it_answers () =
  let reply status =
    Masc_tui_graphics.parse_query_reply
      (Printf.sprintf "i=%d;%s" Masc_tui_graphics.query_id status)
  in
  check bool "OK is support" true (reply "OK" = Some Masc_tui_graphics.Supported);
  check bool "anything else is a refusal, with its reason" true
    (reply "ENOTSUPPORTED:whatever"
     = Some (Masc_tui_graphics.Refused "ENOTSUPPORTED:whatever"));
  (* A reply about a different image is not an answer to this question. A
     terminal drawing pictures answers about those too. *)
  check bool "another image's reply is not this answer" true
    (Masc_tui_graphics.parse_query_reply "i=7;OK" = None);
  check bool "a body that is not a reply at all" true
    (Masc_tui_graphics.parse_query_reply "nonsense" = None);
  (* i=310 must not be read as i=31. Matching on a prefix would. *)
  check bool "a longer id is a different id" true
    (Masc_tui_graphics.parse_query_reply
       (Printf.sprintf "i=%d0;OK" Masc_tui_graphics.query_id)
     = None)
;;

(* tmux stops forwarding at the first ESC it sees inside a passthrough, so
   every ESC in the payload has to be doubled. Undoubling has to give back
   exactly what went in. *)
let test_tmux_passthrough_doubles_every_escape () =
  let payload = Masc_tui_graphics.query in
  let wrapped = Masc_tui_graphics.tmux_wrapped payload in
  let prefix = "\x1bPtmux;" in
  if not (String.starts_with ~prefix wrapped) then
    failf "not a tmux passthrough: %S" wrapped;
  if not (String.ends_with ~suffix:"\x1b\\" wrapped) then
    failf "passthrough not terminated: %S" wrapped;
  let inner =
    String.sub wrapped (String.length prefix)
      (String.length wrapped - String.length prefix - 2)
  in
  (* Every ESC in the payload became two, so splitting the wrapped bytes on
     ESC leaves an empty part between each pair. Dropping those and rejoining
     with one ESC is the inverse. *)
  let undoubled =
    String.concat "\x1b"
      (String.split_on_char '\x1b' inner
       |> List.filteri (fun index _ -> index mod 2 = 0))
  in
  check string "survives the round trip" payload undoubled
;;

let test_iterm2_places_inline_image () =
  let data = "test_image_bytes" in
  let escape =
    Masc_tui_graphics.iterm2_place ~data
      { Masc_tui_graphics.columns = 30; rows = 15 }
  in
  check bool "starts with iTerm2 OSC 1337 introducer" true
    (String.starts_with ~prefix:"\x1b]1337;File=inline=1;width=30;height=15;preserveAspectRatio=1:" escape);
  check bool "ends with BEL terminator" true
    (String.ends_with ~suffix:"\x07" escape);
  let empty =
    Masc_tui_graphics.iterm2_place ~data:""
      { Masc_tui_graphics.columns = 10; rows = 10 }
  in
  check string "empty data produces empty escape" "" empty
;;

let () =
  run
    "tui_graphics"
    [ ( "place"
      , [ test_case "the payload is the file" `Quick
            test_the_payload_is_the_file
        ; test_case "every chunk but the last says more" `Quick
            test_every_chunk_but_the_last_says_more
        ; test_case "only the first escape describes the image" `Quick
            test_only_the_first_escape_describes_the_image
        ; test_case "the named format is the one the escape asks for" `Quick
            test_the_named_format_is_the_one_the_escape_asks_for
        ; test_case "an empty image places nothing" `Quick
            test_an_empty_image_places_nothing
        ; test_case "iterm2 places inline image" `Quick
            test_iterm2_places_inline_image
        ] )
    ; ( "capability"
      , [ test_case "the query asks without drawing" `Quick
            test_the_query_asks_without_drawing
        ; test_case "a reply is read for what it answers" `Quick
            test_a_reply_is_read_for_what_it_answers
        ] )
    ; ( "tmux"
      , [ test_case "passthrough doubles every escape" `Quick
            test_tmux_passthrough_doubles_every_escape
        ] )
    ]
;;
