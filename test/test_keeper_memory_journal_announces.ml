(** A memory journal row is announced once it is durable.

    An external SSE subscriber counts [keeper_memory_journal_appended] frames
    for one Keeper while the current memory is replaced; each replace appends
    one journal row. *)

open Masc
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types

let keeper_id = "memory-journal-announces-keeper"

let journal_appended_for frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields = Some (`String "keeper_memory_journal_appended")
       && List.assoc_opt "name" fields = Some (`String keeper_id)
     | _ -> false
     | exception Yojson.Json_error _ -> false)
;;

let fact claim : Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = { kind = Types.Authored; trace_id = "trace" }
  ; basis = Types.Observed Types.Transcript
  }
;;

let with_heard f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keepers_dir = Filename.temp_file "memory-journal-announces-" ".dir" in
  Sys.remove keepers_dir;
  Unix.mkdir keepers_dir 0o700;
  let heard = ref 0 in
  let subscriber_id =
    Printf.sprintf "memory-journal-announces-%d-%d" (Unix.getpid ()) (Random.int 1_000_000)
  in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree keepers_dir)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external subscriber_id);
       Sse.subscribe_external ~id:subscriber_id
         ~callback:(fun (ev : Sse.external_event) ->
           if journal_appended_for ev.Sse.ext_frame then incr heard)
         ();
       f ~keepers_dir heard)
;;

let replace ~keepers_dir ~expected_revision ~now claim =
  match
    Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
      ~source:{ Current.kind = Current.Librarian; trace_id = "trace" }
      ~facts:[ fact claim ] ()
  with
  | Ok current -> current
  | Error detail -> Alcotest.fail detail
;;

let readable_journal_tail ~keepers_dir ~keeper_id ~limit =
  match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit with
  | Ok rows -> rows
  | Error detail -> failwith ("memory journal unreadable: " ^ detail)
;;

let journal_rows ~keepers_dir =
  List.length (readable_journal_tail ~keepers_dir ~keeper_id ~limit:100)
;;

let test_each_journal_row_is_heard () =
  with_heard @@ fun ~keepers_dir heard ->
  let first = replace ~keepers_dir ~expected_revision:None ~now:200.0 "first fact" in
  let rows_after_first = journal_rows ~keepers_dir in
  Alcotest.(check int) "the first journal row is heard" rows_after_first !heard;
  ignore
    (replace ~keepers_dir ~expected_revision:(Some first.revision) ~now:300.0 "second fact"
      : Current.t);
  Alcotest.(check int) "every journal row is heard once" (journal_rows ~keepers_dir) !heard;
  Alcotest.(check bool) "the replaces wrote journal rows" true (!heard > rows_after_first)
;;

let () =
  Alcotest.run "keeper_memory_journal_announces"
    [ ( "journal"
      , [ Alcotest.test_case "each journal row is heard" `Quick
            test_each_journal_row_is_heard
        ] )
    ]
;;
