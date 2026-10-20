(** Whether a verdict about a Task has a Keeper queue to go to.

    The rejection delivery asks {!Masc.Keeper_producer_route.resolve} twice,
    the second time while holding the backlog lock, so the answer must come
    from a read that writes nothing: a meta it cannot decode stays as it is
    and answers [Error], never {!Masc.Keeper_producer_route.No_keeper}. *)
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

(* A meta the exact decoder refuses: the enumerated field carries a value that
   is not one of its own (#28844). *)
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

(* A past mtime no write can keep: a rewrite stamps the current time. *)
let pinned_mtime = 1_000_000_000.0

let file_mtime path = (Unix.stat path).Unix.st_mtime

let is_no_keeper = function
  | Ok Route.No_keeper -> true
  | Ok (Route.Keeper _) | Error _ -> false

let test_no_entry_and_no_file_is_no_keeper () =
  with_workspace (fun config ->
    Alcotest.(check bool) "nothing carries this name" true
      (is_no_keeper (Route.resolve ~config producer));
    Alcotest.(check bool) "a blank name names nothing" true
      (is_no_keeper (Route.resolve ~config "   ")))

let test_a_meta_file_is_a_keeper () =
  with_workspace (fun config ->
    persist_meta config producer;
    match Route.resolve ~config producer with
    | Ok (Route.Keeper name) ->
      Alcotest.(check string) "a stopped Keeper still has a queue" producer name
    | Ok Route.No_keeper -> Alcotest.fail "a meta file read as no Keeper"
    | Error detail -> Alcotest.fail detail)

(* The in-lock caller relies on this: the read leaves the file exactly as it
   was, bytes and mtime, and the answer is "not now" rather than "no Keeper",
   which costs a skipped release instead of a lost task. *)
let test_an_off_canon_meta_is_not_rewritten () =
  with_workspace (fun config ->
    let bytes = off_canon_meta_bytes producer in
    let path = write_meta_bytes config producer bytes in
    Unix.utimes path pinned_mtime pinned_mtime;
    (match Route.resolve ~config producer with
     | Error _ -> ()
     | Ok Route.No_keeper -> Alcotest.fail "a meta this decoder will not read is not 'no Keeper'"
     | Ok (Route.Keeper _) -> Alcotest.fail "an off-canon meta was decoded as current");
    Alcotest.(check string) "the bytes are exactly as they were" bytes (read_bytes path);
    Alcotest.(check (float 0.)) "the mtime is exactly as it was" pinned_mtime
      (file_mtime path))

(* A file that is not JSON at all is still "there may be a Keeper here". *)
let test_an_unreadable_meta_is_not_no_keeper () =
  with_workspace (fun config ->
    let path = write_meta_bytes config producer "{not json" in
    Alcotest.(check bool) "an unreadable meta is not an absent one" false
      (is_no_keeper (Route.resolve ~config producer));
    Alcotest.(check string) "and it is left alone" "{not json" (read_bytes path))

let () =
  Alcotest.run "keeper_producer_route"
    [ ( "resolve writes nothing"
      , [ Alcotest.test_case "no entry and no file is no Keeper" `Quick
            test_no_entry_and_no_file_is_no_keeper
        ; Alcotest.test_case "a meta file is a Keeper" `Quick test_a_meta_file_is_a_keeper
        ; Alcotest.test_case "an off-canon meta is not rewritten" `Quick
            test_an_off_canon_meta_is_not_rewritten
        ; Alcotest.test_case "an unreadable meta is not no Keeper" `Quick
            test_an_unreadable_meta_is_not_no_keeper
        ] )
    ]
