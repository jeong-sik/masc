(** Pin the operation failure vocabulary against what is already on disk.

    #27981 closed [Keeper_chat_operation.failure_kind] to seven constructors.
    Three call sites stopped compiling, which CI caught. What it did not catch
    is that [failure_kind_of_string] returns [Error] for anything outside the
    set, and the live queues hold failed receipts naming kinds that were left
    out: turn_failed (52), no_visible_reply (15), cancelled (9),
    transcript_persist_failed (1) across the eight chat-queue databases.

    A decoder that refuses its own history is the shape of #27393, where a
    field removal made every durable file with that field unloadable and took
    autoboot to 0/7. #27401 filed the general form. These cases keep the
    reading side able to read what the writing side has already written.

    The producer-side coverage is enforced by the compiler instead: the
    mapping from [queued_turn_failure_kind] lives in one exhaustive match in
    server_routes_http_keeper_stream.ml, so a kind added on either side is a
    build error rather than a value that fails to parse at read time. *)

open Masc
module Op = Keeper_chat_operation

let fail_if condition message =
  if condition
  then (
    prerr_endline ("test_keeper_chat_operation_failure_kind: " ^ message);
    exit 1)
;;

let decodes what value =
  match Op.failure_kind_of_string value with
  | Ok _ -> ()
  | Error detail ->
    fail_if true (Printf.sprintf "%s %S must decode, got: %s" what value detail)
;;

let () =
  (* Every constructor round-trips through its own rendering. This is what
     stops a constructor being added to the type and forgotten in one of the
     two string functions. *)
  List.iter
    (fun kind ->
      let rendered = Op.failure_kind_to_string kind in
      match Op.failure_kind_of_string rendered with
      | Ok decoded ->
        fail_if
          (decoded <> kind)
          (Printf.sprintf "round trip changed %s" rendered)
      | Error detail ->
        fail_if true (Printf.sprintf "%s did not round trip: %s" rendered detail))
    Op.all_failure_kinds;

  (* all_failure_kinds must actually list them all. A constructor missing here
     would make the loop above vacuous for that constructor. *)
  fail_if
    (List.length Op.all_failure_kinds < 13)
    (Printf.sprintf
       "all_failure_kinds has %d entries; the type declares more"
       (List.length Op.all_failure_kinds));

  (* The spellings observed in live receipt_json. The writer that produced
     them uses lowercase snake case; failure_kind_to_string emits PascalCase.
     Reading is where history arrives, so both are accepted. *)
  List.iter
    (decodes "live receipt spelling")
    [ "turn_failed"
    ; "no_visible_reply"
    ; "cancelled"
    ; "transcript_persist_failed"
    ; "turn_cancelled"
    ; "missing_turn_ref"
    ; "stream_projection_failed"
    ];

  (* And the kinds #27981 left out, in the rendering this module emits. *)
  List.iter
    (decodes "kind restored after #27981")
    [ "Turn_failed"
    ; "No_visible_reply"
    ; "Missing_turn_ref"
    ; "Transcript_persist_failed"
    ; "Stream_projection_failed"
    ; "Delivery_failed"
    ];

  (* Widening the decoder is only correct if it still refuses what is not a
     kind: without this, accepting everything would pass every case above. *)
  (match Op.failure_kind_of_string "not_a_failure_kind_at_all" with
   | Error _ -> ()
   | Ok _ ->
     fail_if true "decoder accepted a value that is not a failure kind");

  print_endline
    (Printf.sprintf
       "test_keeper_chat_operation_failure_kind: OK - %d kinds round trip, live \
        spellings decode"
       (List.length Op.all_failure_kinds))
;;
