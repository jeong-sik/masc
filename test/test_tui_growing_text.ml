open Alcotest

module Growing = Masc_tui_growing_text

let safe = Masc_tui_keeper_chat_projection.terminal_safe_text ~preserve_newlines:true

(* Pieces the safe-text conversion reads with context: a ZWJ between
   pictographs, a subdivision flag's tags, selectors after a text-default
   emoji, skin tones, combining marks; and pieces it replaces: controls,
   escape sequences, C1, invalid and cut UTF-8. *)
let pieces =
  [| "a"; "Z "; "\n"; "\n"; "\n\n"; "한"; "\xF0\x9F\x91\xA8"; "\xE2\x80\x8D"; "\xF0\x9F\x92\xBB";
     "\xEF\xB8\x8F"; "\xE2\x9D\xA4"; "\xF0\x9F\x8F\xB4"; "\xF3\xA0\x81\xA7"; "\xF3\xA0\x81\xA2";
     "\xF3\xA0\x81\xB3"; "\xF3\xA0\x81\xBF"; "\x07"; "\x1b[31m"; "\x7f"; "\xC2\x85"; "\xFF";
     "\xE2\x80"; "\xE2\x80\x8B"; "\xE2\x80\xAE"; "\t"; "\r"; "\xF0\x9F\x8F\xBD"; "\xEF\xB8\x8E";
     "\xC2\xAD"; "x\xCC\x81" |]

let random_text state =
  String.concat ""
    (List.init (1 + Random.State.int state 14) (fun _ ->
       pieces.(Random.State.int state (Array.length pieces))))

(* Cut a text into deltas at any byte, inside a UTF-8 sequence too. *)
let random_deltas state text =
  let rec cut start acc =
    if start >= String.length text then List.rev acc
    else
      let length = 1 + Random.State.int state (String.length text - start) in
      cut (start + length) (String.sub text start length :: acc)
  in
  cut 0 []

let test_snapshots_convert_what_arrived () =
  let state = Random.State.make [| 7 |] in
  for case = 1 to 20_000 do
    let text = random_text state in
    let growing = Growing.create ~stretch:case in
    let arrived = Buffer.create 64 in
    let previous = ref None in
    List.iter (fun delta ->
      Growing.append growing delta;
      Buffer.add_string arrived delta;
      let snapshot = Growing.snapshot growing in
      let expected = safe (Buffer.contents arrived) in
      if not (String.equal snapshot.text expected) then
        failf "case %d: %S converted to %S, expected %S" case (Buffer.contents arrived)
          snapshot.text expected;
      if not (String.equal snapshot.identity (Digest.string snapshot.text)) then
        failf "case %d: identity of %S is not its MD5" case snapshot.text;
      Option.iter (fun (before : Growing.snapshot) ->
        if snapshot.closed < before.closed
           || not (String.equal (String.sub before.text 0 before.closed)
                     (String.sub snapshot.text 0 before.closed))
        then failf "case %d: the closed part of %S changed in %S" case before.text snapshot.text)
        !previous;
      previous := Some snapshot)
      (random_deltas state text)
  done

(* The property the stretch relies on, checked on its own. *)
let test_safe_text_splits_after_a_newline () =
  let state = Random.State.make [| 11 |] in
  let checked = ref 0 in
  for _ = 1 to 50_000 do
    let text = random_text state in
    String.iteri (fun index byte ->
      if Char.equal byte '\n' then begin
        incr checked;
        let head = String.sub text 0 (index + 1)
        and tail = String.sub text (index + 1) (String.length text - index - 1) in
        if not (String.equal (safe text) (safe head ^ safe tail)) then
          failf "%S does not split after byte %d" text index
      end) text
  done;
  check bool "some newline was split" true (!checked > 0)

(* A finished line is converted once: the bytes converted for a stretch grow
   with what arrives, not with the frames that look at it. *)
let test_finished_lines_are_converted_once () =
  let growing = Growing.create ~stretch:1 in
  let line = String.make 1000 'x' ^ "\n" in
  for _ = 1 to 100 do Growing.append growing line done;
  let before = Growing.For_testing.bytes_converted () in
  for _ = 1 to 50 do
    Growing.append growing "y";
    ignore (Growing.snapshot growing : Growing.snapshot)
  done;
  let converted = Growing.For_testing.bytes_converted () - before in
  check bool "fifty snapshots convert the open line, not the 100 KB before it" true
    (converted < 5_000);
  let snapshot = Growing.snapshot growing in
  check int "the closed part is every finished line" (100 * String.length line) snapshot.closed;
  check string "the open line is drawn after them" (String.make 50 'y')
    (String.sub snapshot.text snapshot.closed (String.length snapshot.text - snapshot.closed))

let () =
  run "growing text"
    [ ( "snapshot",
        [ test_case "snapshots convert what arrived" `Quick test_snapshots_convert_what_arrived;
          test_case "safe text splits after a newline" `Quick test_safe_text_splits_after_a_newline;
          test_case "finished lines are converted once" `Quick test_finished_lines_are_converted_once ] ) ]
