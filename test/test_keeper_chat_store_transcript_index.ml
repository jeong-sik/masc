(** The append-once writers of [Keeper_chat_store] answer from an index of the
    transcript's rows. They keep it between appends and bring it up to date
    from the rows written since, their own and any other writer's. These cases
    pin what a writer answers when the transcript changed between two of its
    appends: the same as a writer that reads the whole file. *)

open Alcotest
module K = Masc.Keeper_chat_store
module D = Keeper_chat_delivery_identity

let keeper_name = "transcript-index-fixture"

let with_store f =
  let base_dir = Filename.temp_dir "masc_chat_index_" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_dir) (fun () -> f base_dir)
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs f
;;

let path ~base_dir = K.chat_path ~base_dir ~keeper_name
let bytes ~base_dir = In_channel.with_open_bin (path ~base_dir) In_channel.input_all
let unwrap = function Ok value -> value | Error detail -> fail detail

let write path contents =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents)
;;

(* Bytes another writer puts at the end of the transcript. *)
let append_raw ~base_dir contents =
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_binary ]
    0o600
    (path ~base_dir)
    (fun channel -> Out_channel.output_string channel contents)
;;

type answer =
  | Appended
  | Present of string (* the id of the row that was already there *)
  | Refused of string

let pp_answer ppf = function
  | Appended -> Format.pp_print_string ppf "Appended"
  | Present row_id -> Format.fprintf ppf "Present %s" row_id
  | Refused detail -> Format.fprintf ppf "Refused %S" detail
;;

let answer_testable = testable pp_answer ( = )

let answer = function
  | Ok (K.Appended _) -> Appended
  | Ok (K.Already_present { row_id }) -> Present row_id
  | Error detail -> Refused detail
;;

let check_present label = function
  | Present _ -> ()
  | (Appended | Refused _) as other -> failf "%s: %a" label pp_answer other
;;

let check_refused label ~needle = function
  | Refused detail ->
    if not (String_util.contains_substring detail needle)
    then failf "%s: %S is missing from %S" label needle detail
  | (Appended | Present _) as other -> failf "%s: %a" label pp_answer other
;;

let key name =
  match D.Request_id.of_string name with
  | Ok id -> D.Operation id
  | Error detail -> fail detail
;;

let question name ~base_dir =
  K.append_user_message_once
    ~base_dir
    ~keeper_name
    ~delivery_key:(key name)
    ~content:("question " ^ name)
    ()
  |> answer
;;

(* A question whose one row is longer than everything [warm] writes. *)
let long_question name ~base_dir =
  K.append_user_message_once
    ~base_dir
    ~keeper_name
    ~delivery_key:(key name)
    ~content:(String.make 4096 'q')
    ()
  |> answer
;;

let reply name ~base_dir =
  K.append_assistant_message_once
    ~base_dir
    ~keeper_name
    ~delivery_key:(key name)
    ~content:("reply " ^ name)
    ()
  |> answer
;;

let turn absolute_turn = Ids.Turn_ref.make ~trace_id:"trace-transcript-index" ~absolute_turn

let tools turn_ref execution_ids ~base_dir =
  let input_binding =
    [ unwrap
        (D.approval_input_binding
           ~approval_id:"approval-a"
           ~input_fingerprint:(String.make 64 'a'))
    ]
  in
  let call id : K.tool_call =
    { call_id = "call-" ^ id
    ; execution_id = Some (Ids.Execution_id.of_string id)
    ; call_name = "Read"
    ; args = "{}"
    }
  in
  K.append_autonomous_tool_calls_once
    ~base_dir
    ~keeper_name
    ~turn_ref
    ~input_binding
    ~tool_calls:(List.map call execution_ids)
    ()
  |> Result.map fst
  |> answer
;;

(* The rows [deliver] writes in a store of its own: what another writer would
   put in a transcript. *)
let rows_of deliver =
  with_store (fun donor ->
    check answer_testable "the donor delivery" Appended (deliver ~base_dir:donor);
    bytes ~base_dir:donor)
;;

(* What [deliver] answers in a new store that holds the same bytes, or no
   transcript when there is none yet. That store has no index, so its writer
   reads the whole file. *)
let in_copy ~base_dir deliver =
  with_store (fun copy ->
    if Sys.file_exists (path ~base_dir)
    then (
      Fs_compat.mkdir_p (Filename.dirname (path ~base_dir:copy));
      write (path ~base_dir:copy) (bytes ~base_dir));
    deliver ~base_dir:copy)
;;

(* Two rows and a third call that reads both, so the kept index covers the
   whole file and the next call starts reading at its end. *)
let warm ~base_dir =
  check answer_testable "the first question" Appended (question "warm" ~base_dir);
  check answer_testable "its reply" Appended (reply "warm" ~base_dir);
  check_present "the reply, asked again" (reply "warm" ~base_dir)
;;

(* Two questions and their replies: longer than what [warm] leaves. *)
let another_transcript () =
  with_store (fun donor ->
    List.iter
      (fun name ->
         check answer_testable "a donor question" Appended (question name ~base_dir:donor);
         check answer_testable "a donor reply" Appended (reply name ~base_dir:donor))
      [ "other-a"; "other-b" ];
    bytes ~base_dir:donor)
;;

let test_rows_of_another_writer_are_found () =
  with_store (fun base_dir ->
    warm ~base_dir;
    append_raw ~base_dir (rows_of (question "other"));
    let before = bytes ~base_dir in
    check_present "a delivery another writer stored" (question "other" ~base_dir);
    check string "nothing was written for it" before (bytes ~base_dir);
    check_present "a delivery from before" (question "warm" ~base_dir);
    check answer_testable "a delivery nobody stored" Appended (question "new" ~base_dir))
;;

let test_rows_without_provenance_do_not_hide_a_delivery () =
  with_store (fun base_dir ->
    warm ~base_dir;
    K.append_assistant_message ~base_dir ~keeper_name ~content:"a row without provenance" ();
    K.append_user_message ~base_dir ~keeper_name ~content:"another one" ();
    check_present "a delivery from before those rows" (reply "warm" ~base_dir);
    check answer_testable "a new delivery" Appended (question "next" ~base_dir);
    check_present "the new delivery, asked again" (question "next" ~base_dir))
;;

(* Every line of the transcript, each ending with its newline and reading as
   one JSON value. *)
let row_count label ~base_dir =
  let contents = bytes ~base_dir in
  check bool (label ^ ": the transcript ends with a newline") true
    (String.ends_with ~suffix:"\n" contents);
  let rows = List.filter (fun line -> line <> "") (String.split_on_char '\n' contents) in
  List.iter
    (fun row ->
       match Yojson.Safe.from_string row with
       | _ -> ()
       | exception Yojson.Json_error detail -> failf "%s: %S is not one row: %s" label row detail)
    rows;
  List.length rows
;;

(* The row of [question "other"] with its last byte, the newline, missing:
   what an append leaves when the process dies one byte short. *)
let other_without_its_newline () =
  let row = rows_of (question "other") in
  check bool "the donor row ends with a newline" true (String.ends_with ~suffix:"\n" row);
  String.sub row 0 (String.length row - 1)
;;

let test_a_last_row_without_its_newline_is_written_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    append_raw ~base_dir (other_without_its_newline ());
    check answer_testable "a delivery whose row has no newline" Appended
      (question "other" ~base_dir);
    check int "the two rows of [warm] and one row for it" 3
      (row_count "after the delivery" ~base_dir);
    check_present "the same delivery, asked again" (question "other" ~base_dir);
    check int "nothing more was written" 3 (row_count "asked again" ~base_dir))
;;

let test_a_row_is_not_joined_to_a_last_row_without_its_newline () =
  with_store (fun base_dir ->
    warm ~base_dir;
    append_raw ~base_dir (other_without_its_newline ());
    check answer_testable "another delivery" Appended (question "next" ~base_dir);
    check int "the two rows of [warm] and the new row" 3
      (row_count "after another delivery" ~base_dir);
    check_present "the new delivery, asked again" (question "next" ~base_dir);
    check_present "a delivery from before the cut" (reply "warm" ~base_dir);
    check answer_testable "the delivery whose append stopped" Appended
      (question "other" ~base_dir);
    check int "one row more" 4 (row_count "after it was sent again" ~base_dir))
;;

let test_a_replaced_transcript_is_read_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    let old = bytes ~base_dir in
    let other = another_transcript () in
    check bool "the replacement is longer than what was read" true
      (String.length other > String.length old);
    (* Renamed over the path while the old file still exists: another inode. *)
    let replacement = path ~base_dir ^ ".new" in
    write replacement other;
    Sys.rename replacement (path ~base_dir);
    check answer_testable "a delivery only the old file held" Appended (question "warm" ~base_dir);
    check_present "a delivery the new file holds" (reply "other-b" ~base_dir))
;;

let test_a_shortened_transcript_is_read_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    let first_row = String.index (bytes ~base_dir) '\n' + 1 in
    Unix.truncate (path ~base_dir) first_row;
    check answer_testable "the reply that was cut off" Appended (reply "warm" ~base_dir);
    check_present "the question that stayed" (question "warm" ~base_dir))
;;

let test_a_purged_transcript_is_read_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    check (list string) "the transcript as loaded before the purge"
      [ "question warm"; "reply warm" ]
      (List.map (fun (message : K.chat_message) -> message.K.content)
         (K.load_all ~base_dir ~keeper_name));
    let old = bytes ~base_dir in
    let other = another_transcript () in
    check bool "the new transcript is longer than what was read" true
      (String.length other > String.length old);
    (* The same inode on purpose. After a removal a new file at the path can
       get the old inode number, and then nothing but the purge tells the two
       files apart. *)
    K.purge_transcript (path ~base_dir) ~remove:(fun path -> write path other);
    check (list string) "the loaded transcript is the new one"
      [ "question other-a"; "reply other-a"; "question other-b"; "reply other-b" ]
      (List.map (fun (message : K.chat_message) -> message.K.content)
         (K.load_all ~base_dir ~keeper_name));
    check_present "a delivery the new transcript holds" (reply "other-b" ~base_dir);
    check answer_testable "a delivery only the purged transcript held" Appended
      (question "warm" ~base_dir))
;;

let test_a_transcript_rewritten_across_the_kept_place_is_read_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    let read_end = String.length (bytes ~base_dir) in
    let other = rows_of (long_question "other") in
    check bool "the new row ends after the place the reading ended" true
      (String.length other > read_end);
    (* Written through the path: the same inode, and longer than what was
       read. The place the reading ended lies inside the one new row. *)
    write (path ~base_dir) other;
    check answer_testable "a delivery only the old rows held" Appended (question "warm" ~base_dir);
    check_present "the delivery the new row holds" (long_question "other" ~base_dir))
;;

(* Fibers that deliver at the same time take turns at the transcript. Each
   reads the rows the one before it wrote, and no row goes into the index
   twice. *)
let test_fibers_take_turns_at_a_transcript () =
  with_eio_fs (fun () ->
    with_store (fun base_dir ->
      warm ~base_dir;
      let names = List.init 6 (Printf.sprintf "fiber-%d") in
      (* Every delivery twice, each from a fiber of its own. *)
      let answers =
        Eio.Fiber.List.map (fun name -> name, question name ~base_dir) (names @ names)
      in
      List.iter
        (fun name ->
           let of_name =
             List.filter_map
               (fun (asked, answer) -> if String.equal asked name then Some answer else None)
               answers
           in
           match of_name with
           | [ Appended; Present _ ] | [ Present _; Appended ] -> ()
           | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ ->
             failf
               "%s: %a"
               name
               (Format.pp_print_list ~pp_sep:Format.pp_print_space pp_answer)
               of_name)
        names;
      check_present "a delivery from before the fibers" (reply "warm" ~base_dir)))
;;

(* A fiber that is cancelled before it delivers writes nothing and is not
   answered. The delivery then goes in when it is asked again. *)
let test_a_cancelled_fiber_writes_nothing () =
  with_eio_fs (fun () ->
    with_store (fun base_dir ->
      warm ~base_dir;
      let before = bytes ~base_dir in
      (match
         Eio.Cancel.sub (fun context ->
           Eio.Cancel.cancel context Exit;
           question "cancelled" ~base_dir)
       with
       | exception Eio.Cancel.Cancelled _ -> ()
       | (Appended | Present _ | Refused _) as answered ->
         failf "a cancelled fiber was answered: %a" pp_answer answered);
      check string "the transcript" before (bytes ~base_dir);
      check
        answer_testable
        "the same delivery, asked again"
        Appended
        (question "cancelled" ~base_dir)))
;;

let test_an_unreadable_row_refuses_every_delivery () =
  with_store (fun base_dir ->
    warm ~base_dir;
    (* Lines 1 and 2 are the rows of [warm]. *)
    append_raw ~base_dir "not a row\n";
    let at_line_3 label answer = check_refused label ~needle:"at line 3" answer in
    at_line_3 "a new delivery" (question "next" ~base_dir);
    append_raw ~base_dir (rows_of (question "other"));
    let before = bytes ~base_dir in
    at_line_3 "the same delivery after another row arrived" (question "next" ~base_dir);
    at_line_3 "a delivery stored before the unreadable row" (question "warm" ~base_dir);
    at_line_3 "a delivery stored after it" (question "other" ~base_dir);
    check string "nothing was written" before (bytes ~base_dir))
;;

let test_a_torn_tail_is_cut_by_the_next_delivery () =
  with_store (fun base_dir ->
    warm ~base_dir;
    append_raw ~base_dir {|{"id":"msg-torn","role":"us|};
    check answer_testable "a delivery behind a torn row" Appended (question "next" ~base_dir);
    check int "the two rows of [warm] and the new row" 3 (row_count "after the cut" ~base_dir);
    check_present "a delivery from before the fragment" (reply "warm" ~base_dir))
;;

(* A delivery that was refused is asked of the whole file the next time. Both
   rewrites here keep the inode, the length and a row start where the reading
   ended, so nothing about the file tells the old rows from the new ones. *)
let test_a_refused_delivery_is_asked_of_the_whole_file_again () =
  with_store (fun base_dir ->
    warm ~base_dir;
    let read_end = String.length (bytes ~base_dir) in
    let other = rows_of (question "other") in
    check bool "one row is shorter than the two that were read" true
      (String.length other < read_end);
    (* Empty lines are not rows. They bring the next row to the place the
       reading ended. *)
    let up_to_read_end = other ^ String.make (read_end - String.length other) '\n' in
    write (path ~base_dir) (up_to_read_end ^ "not a row\n");
    (match question "warm" ~base_dir with
     | Refused _ -> ()
     | (Appended | Present _) as answered ->
       failf "a delivery behind an unreadable row: %a" pp_answer answered);
    write (path ~base_dir) (up_to_read_end ^ rows_of (question "repaired"));
    check answer_testable "a delivery only the first rows held" Appended (question "warm" ~base_dir);
    check_present "a delivery the repaired transcript holds" (question "repaired" ~base_dir);
    check_present "another one it holds" (question "other" ~base_dir))
;;

let test_tool_rows_wait_for_their_binding_row () =
  with_store (fun base_dir ->
    warm ~base_dir;
    let turn_ref = turn 7 in
    let binding_row, tool_row =
      match String.split_on_char '\n' (rows_of (tools turn_ref [ "exec-a" ])) with
      | [ binding_row; tool_row; "" ] -> binding_row, tool_row
      | lines ->
        failf "the fixture turn wrote %d rows, not a binding row and a tool row"
          (List.length lines - 1)
    in
    append_raw ~base_dir (tool_row ^ "\n");
    check_refused
      "tool rows whose binding row is missing"
      ~needle:"autonomous tool rows have no input binding"
      (tools turn_ref [ "exec-a" ] ~base_dir);
    append_raw ~base_dir (binding_row ^ "\n");
    let whole_read = in_copy ~base_dir (tools turn_ref [ "exec-a" ]) in
    check_present "a whole read, once the binding row arrived" whole_read;
    check answer_testable "the kept index answers the same" whole_read
      (tools turn_ref [ "exec-a" ] ~base_dir))
;;

type step =
  | Deliver of (base_dir:string -> answer)
  | Other_writer of string
  | Row_without_provenance

type expected =
  | Is_appended
  | Is_present
  | Is_refused

(* Each delivery is asked twice: of a copy of the transcript in a new store,
   whose writer reads the whole file, and of the transcript itself, whose
   writer has read every earlier step. The two must give the same answer. *)
let test_a_kept_index_answers_as_a_whole_read_does () =
  with_store (fun base_dir ->
    let turn_a = turn 1
    and turn_b = turn 2 in
    let other = rows_of (question "other") in
    let steps =
      [ "question a", Deliver (question "a"), Some Is_appended
      ; "reply a", Deliver (reply "a"), Some Is_appended
      ; "question a again", Deliver (question "a"), Some Is_present
      ; "a row without provenance", Row_without_provenance, None
      ; "question b", Deliver (question "b"), Some Is_appended
      ; "another writer stores question other", Other_writer other, None
      ; "question other", Deliver (question "other"), Some Is_present
      ; "reply other", Deliver (reply "other"), Some Is_appended
      ; "a tool of turn 1", Deliver (tools turn_a [ "exec-a" ]), Some Is_appended
      ; "one more tool of turn 1", Deliver (tools turn_a [ "exec-a"; "exec-b" ]), Some Is_appended
      ; "the same tools again", Deliver (tools turn_a [ "exec-a"; "exec-b" ]), Some Is_present
      ; "turn 2 claims an execution of turn 1", Deliver (tools turn_b [ "exec-a" ]), Some Is_refused
      ; "another writer stores question other again", Other_writer other, None
      ; "question other, now stored twice", Deliver (question "other"), Some Is_refused
      ; "reply b", Deliver (reply "b"), Some Is_appended
      ; "question c", Deliver (question "c"), Some Is_appended
      ]
    in
    List.iter
      (fun (label, step, expected) ->
         match step, expected with
         | Row_without_provenance, _ ->
           K.append_assistant_message ~base_dir ~keeper_name ~content:"a row without provenance" ()
         | Other_writer rows, _ -> append_raw ~base_dir rows
         | Deliver deliver, expected ->
           let whole_read = in_copy ~base_dir deliver in
           let kept = deliver ~base_dir in
           check answer_testable (label ^ ": the kept index and a whole read") whole_read kept;
           (match expected, kept with
            | Some Is_appended, Appended
            | Some Is_present, Present _
            | Some Is_refused, Refused _ -> ()
            | (Some (Is_appended | Is_present | Is_refused) | None), (Appended | Present _ | Refused _)
              ->
              failf "%s: %a" label pp_answer kept))
      steps)
;;

let () =
  run
    "keeper_chat_store_transcript_index"
    [ ( "rows written since the last append"
      , [ test_case "rows of another writer are found" `Quick test_rows_of_another_writer_are_found
        ; test_case
            "rows without provenance do not hide a delivery"
            `Quick
            test_rows_without_provenance_do_not_hide_a_delivery
        ; test_case
            "a last row without its newline is written again"
            `Quick
            test_a_last_row_without_its_newline_is_written_again
        ; test_case
            "a row is not joined to a last row without its newline"
            `Quick
            test_a_row_is_not_joined_to_a_last_row_without_its_newline
        ; test_case
            "tool rows wait for their binding row"
            `Quick
            test_tool_rows_wait_for_their_binding_row
        ; test_case
            "a kept index answers as a whole read does"
            `Quick
            test_a_kept_index_answers_as_a_whole_read_does
        ] )
    ; ( "a transcript that is not the one that was read"
      , [ test_case "a replaced transcript is read again" `Quick test_a_replaced_transcript_is_read_again
        ; test_case
            "a shortened transcript is read again"
            `Quick
            test_a_shortened_transcript_is_read_again
        ; test_case "a purged transcript is read again" `Quick test_a_purged_transcript_is_read_again
        ; test_case
            "a transcript rewritten across the kept place is read again"
            `Quick
            test_a_transcript_rewritten_across_the_kept_place_is_read_again
        ] )
    ; ( "rows that cannot be read"
      , [ test_case
            "an unreadable row refuses every delivery"
            `Quick
            test_an_unreadable_row_refuses_every_delivery
        ; test_case
            "a torn tail is cut by the next delivery"
            `Quick
            test_a_torn_tail_is_cut_by_the_next_delivery
        ; test_case
            "a refused delivery is asked of the whole file again"
            `Quick
            test_a_refused_delivery_is_asked_of_the_whole_file_again
        ] )
    ; ( "deliveries at the same time"
      , [ test_case "fibers take turns at a transcript" `Quick test_fibers_take_turns_at_a_transcript
        ; test_case
            "a cancelled fiber writes nothing"
            `Quick
            test_a_cancelled_fiber_writes_nothing
        ] )
    ]
;;
