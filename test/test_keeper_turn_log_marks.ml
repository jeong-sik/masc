(* Counting closed messages and naming a run of them as slices
   (RFC librarian-call-only-proposes §5.1). *)

open Alcotest
module Marks = Masc.Keeper_turn_log_marks
module Objects = Agent_core.Checkpoint_objects

let digest fill =
  match Objects.digest_of_hex (String.make 64 fill) with
  | Ok digest -> digest
  | Error detail -> fail detail
;;

let turn fill messages : Objects.turn =
  { bundle = digest fill; messages; chain = Objects.chain_start }
;;

let history ?segment_messages turns ~open_messages : Objects.history =
  { segment =
      Option.map
        (fun segment_messages : Objects.segment_ref ->
           { segment = digest 'f'; segment_messages; segment_chain = Objects.chain_start })
        segment_messages
  ; turns
  ; open_messages = List.init open_messages (fun (_ : int) -> digest 'e')
  }
;;

let a = turn 'a' 3
let b = turn 'b' 2
let c = turn 'c' 4

let test_closed_messages () =
  check int "an empty history" 0 (Marks.closed_messages (history [] ~open_messages:0));
  check int "open messages are not counted" 5
    (Marks.closed_messages (history [ a; b ] ~open_messages:2));
  check int "the segments' messages are" 49
    (Marks.closed_messages (history ~segment_messages:40 [ a; b; c ] ~open_messages:1))
;;

let slice_text (slice : Masc.Keeper_turn_log.slice) =
  Printf.sprintf "%c+%d:%d" (slice.bundle :> string).[0] slice.skip slice.take
;;

let range_text covered ~from ~through =
  match Marks.slices covered ~from ~through with
  | Ok slices -> String.concat " " (List.map slice_text slices)
  | Error (Starts_before_covered { from; first }) ->
    Printf.sprintf "starts at %d before %d" from first
  | Error (Ends_after_covered { through; last }) ->
    Printf.sprintf "ends at %d after %d" through last
  | Error (Backwards { from; through }) -> Printf.sprintf "backwards %d %d" from through
;;

(* a holds messages 40 to 42, b 43 and 44, c 45 to 48. *)
let head = Marks.of_head (history ~segment_messages:40 [ a; b; c ] ~open_messages:1)

let test_slices () =
  check string "everything the head holds" "a+0:3 b+0:2 c+0:4"
    (range_text head ~from:40 ~through:49);
  check string "a run that starts and ends inside a turn" "a+2:1 b+0:2 c+0:1"
    (range_text head ~from:42 ~through:46);
  check string "exactly one turn" "b+0:2" (range_text head ~from:43 ~through:45);
  check string "inside one turn" "c+1:2" (range_text head ~from:46 ~through:48);
  check string "nothing" "" (range_text head ~from:44 ~through:44);
  check string "nothing at the very end" "" (range_text head ~from:49 ~through:49);
  check string "an empty run before what is covered is still outside it" "starts at 39 before 40"
    (range_text head ~from:39 ~through:39);
  check string "before what the head holds" "starts at 39 before 40"
    (range_text head ~from:39 ~through:44);
  check string "past the last closed message" "ends at 50 after 49"
    (range_text head ~from:44 ~through:50);
  check string "a run that ends before it starts" "backwards 46 45"
    (range_text head ~from:46 ~through:45)
;;

let segment_error_text : string Marks.segment_error -> string = function
  | Nothing_before -> "nothing before"
  | Not_read why -> "not read: " ^ why
  | Does_not_fit { first; segment_messages; has_previous } ->
    Printf.sprintf "%d messages before, the segment holds %d and %s" first segment_messages
      (if has_previous then "names one before it" else "names none before it")
;;

(* A store that holds one segment under one name. *)
let holding name segment asked = if asked = name then Ok segment else Error "another name"

(* The head's segment is named f. *)
let with_segment ?(under = digest 'f') segment covered =
  Marks.with_segment_before ~load:(holding under segment) covered
;;

let before_text ?under segment covered =
  match with_segment ?under segment covered with
  | Ok covered -> Printf.sprintf "from %d" (Marks.first covered)
  | Error error -> segment_error_text error
;;

let test_segment_before () =
  let segment : Objects.segment = { previous = None; segment_turns = [ turn '1' 10; turn '2' 30 ] } in
  check string "the head asks for the segment it names and no other"
    "not read: another name"
    (before_text ~under:(digest 'e') segment head);
  (match with_segment segment head with
   | Error error -> fail (segment_error_text error)
   | Ok covered ->
     check int "the segment's turns start at message 0" 0 (Marks.first covered);
     check string "a run from inside the segment into the head" "1+5:5 2+0:30 a+0:2"
       (range_text covered ~from:5 ~through:42);
     check string "there is no segment to put before message 0" "nothing before"
       (before_text segment covered));
  let earlier : Objects.segment =
    { previous = Some (digest '9'); segment_turns = [ turn '3' 25 ] }
  in
  (match with_segment earlier head with
   | Error error -> fail (segment_error_text error)
   | Ok covered ->
     check int "a segment in the middle" 15 (Marks.first covered);
     check string "it asks next for the one that segment names" "from 0"
       (before_text ~under:(digest '9')
          { previous = None; segment_turns = [ turn '8' 15 ] }
          covered);
     check string "and not again for the head's" "not read: another name"
       (before_text { previous = None; segment_turns = [ turn '8' 15 ] } covered));
  (* Another segment than the one just before is refused, not sliced. *)
  check string "longer than what is before" "40 messages before, the segment holds 50 and names none before it"
    (before_text { previous = None; segment_turns = [ turn '4' 50 ] } head);
  check string "longer than what is before, with one named before it"
    "40 messages before, the segment holds 50 and names one before it"
    (before_text { previous = Some (digest '9'); segment_turns = [ turn '7' 50 ] } head);
  check string "stops short of message 0 and names none before"
    "40 messages before, the segment holds 30 and names none before it"
    (before_text { previous = None; segment_turns = [ turn '5' 30 ] } head);
  check string "reaches message 0 and names one before"
    "40 messages before, the segment holds 40 and names one before it"
    (before_text { previous = Some (digest '9'); segment_turns = [ turn '6' 40 ] } head)
;;

(* A purge folds closed turns into one bundle. The same run of messages is
   then named by other slices, and it is still the same messages. *)
let test_same_messages_however_the_turns_are_cut () =
  let numbers (first, turns) ~from ~through =
    let covered = Marks.of_head (history ~segment_messages:first turns ~open_messages:0) in
    match Marks.slices covered ~from ~through with
    | Error (Starts_before_covered _ | Ends_after_covered _ | Backwards _) -> fail "out of range"
    | Ok slices ->
      let start_of bundle =
        let rec find start = function
          | [] -> fail "a slice names a bundle the history does not hold"
          | (turn : Objects.turn) :: rest ->
            if String.equal (turn.bundle :> string) (bundle : Objects.digest :> string)
            then start
            else find (start + turn.messages) rest
        in
        find first turns
      in
      List.concat_map
        (fun (slice : Masc.Keeper_turn_log.slice) ->
           List.init slice.take (fun index -> start_of slice.bundle + slice.skip + index))
        slices
  in
  let head = 40, [ a; b; c ] in
  let folded = 40, [ turn 'd' 9 ] in
  List.iter
    (fun (from, through) ->
       let expected = List.init (through - from) (fun index -> from + index) in
       check (list int) "as three turns" expected (numbers head ~from ~through);
       check (list int) "as one bundle" expected (numbers folded ~from ~through))
    [ 40, 49; 42, 46; 43, 45; 44, 44; 48, 49 ]
;;

let () =
  run "keeper_turn_log_marks"
    [ "count", [ test_case "closed messages" `Quick test_closed_messages ]
    ; ( "slices"
      , [ test_case "a run of messages" `Quick test_slices
        ; test_case "a run that starts in the segment before" `Quick test_segment_before
        ; test_case "the same messages however the turns are cut" `Quick
            test_same_messages_however_the_turns_are_cut
        ] )
    ]
;;
