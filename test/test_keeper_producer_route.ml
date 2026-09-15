(** Whether a verdict about a Task has a Keeper queue to go to, asked the two
    ways this question gets asked.

    {!Masc.Keeper_producer_route.resolve} may repair an off-canon meta in place
    — a durable rewrite and an fsync of another Keeper's file. The rejection
    delivery asks the same question a second time while holding the backlog
    lock, and that lock is a lease with a wall-clock expiry: a write inside it
    widens the window where it expires while still held. So the in-lock caller
    asks through a reader that writes nothing. *)
module Route = Masc.Keeper_producer_route
module W = Workspace_core

let () = Mirage_crypto_rng_unix.use_default ()

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let producer = "vanished-mcp-client"

let with_workspace f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let base_path = Filename.temp_dir "masc-producer-route-" "" in
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.on_release sw (fun () ->
        Fs_compat.clear_fs ();
        Masc_test_deps.cleanup_test_workspace base_path);
      let config = W.default_config base_path in
      ignore (W.init config ~agent_name:(Some "route-fixture"));
      f config))

let meta_path config name = Masc.Keeper_types_profile.keeper_meta_path config name

let write_meta_bytes config name bytes =
  let path = meta_path config name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_text path (fun out -> output_string out bytes);
  path

let read_bytes path = In_channel.with_open_text path In_channel.input_all

(* A meta the exact decoder refuses and the repair decoder accepts: the one
   repairable enumerated field carries a value that is not one of its own
   (#28844). Reading this through [resolve] rewrites the file. *)
let off_canon_meta_bytes name =
  let meta =
    ok (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]))
  in
  match Masc.Keeper_meta_json.meta_to_json meta with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
        (("last_proactive_outcome", `String "not-one-of-the-outcomes")
         :: List.remove_assoc "last_proactive_outcome" fields))
  | _ -> Alcotest.fail "a keeper meta serialises as an object"

let persist_meta config name =
  let meta =
    ok (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]))
  in
  ok
    (Masc.Keeper_fs.save_json_atomic
       (meta_path config name)
       (Masc.Keeper_meta_json.meta_to_json meta))

let test_no_entry_and_no_file_is_no_queue () =
  with_workspace (fun config ->
    Alcotest.(check bool) "nothing carries this name" true
      (Route.has_no_queue_without_writing ~config producer);
    Alcotest.(check bool) "a blank name names nothing" true
      (Route.has_no_queue_without_writing ~config "   "))

let test_a_meta_file_is_a_queue () =
  with_workspace (fun config ->
    persist_meta config producer;
    Alcotest.(check bool) "a stopped Keeper still has a queue" false
      (Route.has_no_queue_without_writing ~config producer))

(* The whole reason this function exists. The same file read through [resolve]
   is rewritten; read through this one it is not touched, and the answer is
   the direction that costs a skipped release rather than a lost task. *)
let test_an_off_canon_meta_is_not_rewritten () =
  with_workspace (fun config ->
    let bytes = off_canon_meta_bytes producer in
    let path = write_meta_bytes config producer bytes in
    Alcotest.(check bool) "a meta this decoder will not read is not 'no queue'"
      false
      (Route.has_no_queue_without_writing ~config producer);
    Alcotest.(check string) "and the file is exactly as it was" bytes (read_bytes path);
    (* The repairing reader does write, which is why the caller under the lock
       must not use it. If this stops being true the in-lock reader can go. *)
    (match Route.resolve ~config producer with
     | Ok _ | Error _ -> ());
    Alcotest.(check bool) "the repairing read rewrote the same file" true
      (not (String.equal bytes (read_bytes path))))

(* A file that is not JSON at all reaches neither decoder's repair path, and
   the answer is still "there may be a Keeper here". *)
let test_an_unreadable_meta_is_not_no_queue () =
  with_workspace (fun config ->
    let path = write_meta_bytes config producer "{not json" in
    Alcotest.(check bool) "an unreadable meta is not an absent one" false
      (Route.has_no_queue_without_writing ~config producer);
    Alcotest.(check string) "and it is left alone" "{not json" (read_bytes path))

let () =
  Alcotest.run "keeper_producer_route"
    [ ( "asked without writing"
      , [ Alcotest.test_case "no entry and no file is no queue" `Quick
            test_no_entry_and_no_file_is_no_queue
        ; Alcotest.test_case "a meta file is a queue" `Quick test_a_meta_file_is_a_queue
        ; Alcotest.test_case "an off-canon meta is not rewritten" `Quick
            test_an_off_canon_meta_is_not_rewritten
        ; Alcotest.test_case "an unreadable meta is not no queue" `Quick
            test_an_unreadable_meta_is_not_no_queue
        ] )
    ]
