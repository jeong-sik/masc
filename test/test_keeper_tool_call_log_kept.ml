(** [Keeper_tool_call_log.read_latest] takes the ledger store's kept window of
    its newest rows ([Dated_jsonl.last_rows]).

    This executable stands for the server: it says it is the one process that
    writes the stores before any test runs.

    What is pinned:

    1. Once read, a Keeper's newest call comes from memory. It is answered
       with the day files gone, until the store is told of the removal.
    2. A logged call moves the kept window.
    3. A Keeper whose newest call lies before the window has none.
    4. Without a Keeper only the ledger's last row is looked at: a last row
       that is not JSON gives none, while a Keeper's call before it is still
       found.
    5. With the read index in the ledger's directory, as in the server, the
       window is filled and kept, and it answers as the indexed reader does.
    6. A ledger the strict read refuses keeps nothing and is read leniently
       on each call, newest row first. *)

open Alcotest
open Masc

(* A workspace whose ledger is open, and a handle on the ledger's store for
   looking at its files. *)
let with_ledger f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Keeper_tool_call_log.init ~base_path ();
      f
        (Dated_jsonl.open_store
           Dated_jsonl.Store.(at (root_of_base_path ~base_path) Root.Tool_calls)))
;;

let log ~keeper_name ~tool_name =
  Keeper_tool_call_log.log_call
    ~keeper_name
    ~tool_name
    ~input:(`Assoc [])
    ~output_text:"result"
    ~wire_outcome:Tool_result.Ok
    ~duration_ms:1.0
    ()
;;

(* The tool of the newest call, as the reader tells it. *)
let newest_tool ?keeper_name () =
  Option.bind
    (Keeper_tool_call_log.read_latest ?keeper_name ())
    (Json_util.assoc_string_opt "tool")
;;

(* The ledger's day files, newest first, as the strict listing gives them.
   A directory the indexed reader has read also holds the read index, which
   is not among them. *)
let day_files store =
  let listed = function
    | Ok paths -> paths
    | Error error -> fail (Dated_jsonl.read_error_to_string error)
  in
  List.concat_map
    (fun month -> listed (Dated_jsonl.day_file_paths_newest_first_result month))
    (listed (Dated_jsonl.month_dir_paths_newest_first_result store))
;;

let remove_day_files store = List.iter Sys.remove (day_files store)

(* The second answer has to come from memory: the files it would read are
   gone. Once the store is told of a removal the reader reads the files again
   and finds no call. *)
let test_a_kept_call_is_read_without_the_files () =
  with_ledger (fun store ->
    log ~keeper_name:"alpha" ~tool_name:"first";
    check (option string) "the call" (Some "first") (newest_tool ~keeper_name:"alpha" ());
    remove_day_files store;
    check
      (option string)
      "again with the files gone"
      (Some "first")
      (newest_tool ~keeper_name:"alpha" ());
    check (option string) "and the ledger's last row" (Some "first") (newest_tool ());
    Dated_jsonl.directories_removed ();
    check
      (option string)
      "once the removal is told"
      None
      (newest_tool ~keeper_name:"alpha" ()))
;;

let test_a_logged_call_moves_the_kept_window () =
  with_ledger (fun store ->
    log ~keeper_name:"alpha" ~tool_name:"first";
    check (option string) "the first call" (Some "first") (newest_tool ~keeper_name:"alpha" ());
    log ~keeper_name:"beta" ~tool_name:"second";
    log ~keeper_name:"alpha" ~tool_name:"third";
    remove_day_files store;
    check
      (option string)
      "one Keeper's newest call, with the files gone"
      (Some "third")
      (newest_tool ~keeper_name:"alpha" ());
    check
      (option string)
      "the other Keeper's"
      (Some "second")
      (newest_tool ~keeper_name:"beta" ());
    check (option string) "the ledger's last row" (Some "third") (newest_tool ()))
;;

(* Sixteen calls of another Keeper after it push a Keeper's call out of the
   window. It has no newest call then, as before there was a fact. *)
let test_a_call_before_the_window_is_not_found () =
  with_ledger (fun _ ->
    log ~keeper_name:"alpha" ~tool_name:"early";
    for number = 1 to 15 do
      log ~keeper_name:"beta" ~tool_name:(Printf.sprintf "later-%d" number)
    done;
    check
      (option string)
      "the sixteenth newest row is still in the window"
      (Some "early")
      (newest_tool ~keeper_name:"alpha" ());
    log ~keeper_name:"beta" ~tool_name:"later-16";
    check
      (option string)
      "the seventeenth is not"
      None
      (newest_tool ~keeper_name:"alpha" ());
    check
      (option string)
      "the other Keeper's newest"
      (Some "later-16")
      (newest_tool ~keeper_name:"beta" ()))
;;

(* A row cut short at the end of the ledger. *)
let test_a_last_row_that_is_not_json () =
  with_ledger (fun store ->
    log ~keeper_name:"alpha" ~tool_name:"first";
    let newest_day_file =
      match day_files store with
      | path :: _ -> path
      | [] -> fail "the ledger has no day file"
    in
    Out_channel.with_open_gen
      [ Open_wronly; Open_append; Open_binary ]
      0o644
      newest_day_file
      (fun channel -> output_string channel "{\"keeper\": \n");
    check (option string) "the ledger's last row is not a call" None (newest_tool ());
    check
      (option string)
      "the Keeper's call before it is found"
      (Some "first")
      (newest_tool ~keeper_name:"alpha" ()))
;;

(* The tool of the newest call among the ledger's newest sixteen rows, as the
   indexed reader gives it. Calling it makes the read index. *)
let newest_tool_by_the_index ?keeper_name () =
  match Keeper_tool_call_log.read_recent ?keeper_name ~n:16 () with
  | Error _ -> fail "the indexed reader failed"
  | Ok rows ->
    (match List.rev rows with
     | [] -> None
     | newest :: _ -> Json_util.assoc_string_opt "tool" newest)
;;

(* The server's ledger directory holds the read index beside the month
   directories. With the index there the strict read still reads the store,
   so the window is filled and kept, and its answers are the indexed
   reader's for the same rows. *)
let test_the_window_is_kept_beside_the_read_index () =
  with_ledger (fun store ->
    log ~keeper_name:"alpha" ~tool_name:"first";
    log ~keeper_name:"beta" ~tool_name:"second";
    log ~keeper_name:"alpha" ~tool_name:"third";
    let by_the_index_of_alpha = newest_tool_by_the_index ~keeper_name:"alpha" () in
    let by_the_index_of_beta = newest_tool_by_the_index ~keeper_name:"beta" () in
    let by_the_index = newest_tool_by_the_index () in
    check
      bool
      "the read index is in the ledger's directory"
      true
      (Sys.file_exists
         (Filename.concat (Dated_jsonl.base_dir store) Common.tool_call_read_index_basename));
    check
      bool
      "the strict read passes over it"
      true
      (Result.is_ok (Dated_jsonl.read_recent_result store 1));
    check (option string) "the indexed reader's answer" (Some "third") by_the_index_of_alpha;
    check
      (option string)
      "one Keeper's newest call, as the indexed reader gives it"
      by_the_index_of_alpha
      (newest_tool ~keeper_name:"alpha" ());
    check
      (option string)
      "the other Keeper's"
      by_the_index_of_beta
      (newest_tool ~keeper_name:"beta" ());
    check (option string) "the ledger's last row" by_the_index (newest_tool ());
    remove_day_files store;
    check
      (option string)
      "the window was kept: answered with the day files gone"
      (Some "third")
      (newest_tool ~keeper_name:"alpha" ()))
;;

(* An entry the ledger's store did not declare lies in its directory. The
   strict read refuses the store, so nothing is kept, and each call reads the
   newest rows leniently and looks at them newest first, as this function did
   before there was a fact. *)
let test_a_ledger_the_strict_read_refuses_is_read_leniently () =
  with_ledger (fun store ->
    log ~keeper_name:"alpha" ~tool_name:"first";
    log ~keeper_name:"beta" ~tool_name:"second";
    log ~keeper_name:"alpha" ~tool_name:"third";
    Out_channel.with_open_text
      (Filename.concat (Dated_jsonl.base_dir store) "notes.txt")
      (fun channel -> output_string channel "not dated");
    check
      bool
      "the strict read refuses the ledger"
      true
      (Result.is_error (Dated_jsonl.read_recent_result store 1));
    check (option string) "the ledger's last row" (Some "third") (newest_tool ());
    check
      (option string)
      "one Keeper's newest call"
      (Some "third")
      (newest_tool ~keeper_name:"alpha" ());
    check
      (option string)
      "the other Keeper's"
      (Some "second")
      (newest_tool ~keeper_name:"beta" ());
    log ~keeper_name:"beta" ~tool_name:"fourth";
    check
      (option string)
      "a call logged after it is read too: nothing was kept"
      (Some "fourth")
      (newest_tool ()))
;;

let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_tool_call_log_kept"
    [ ( "the newest calls are the ledger's kept window"
      , [ test_case
            "a kept call is read without the files"
            `Quick
            test_a_kept_call_is_read_without_the_files
        ; test_case
            "a logged call moves the kept window"
            `Quick
            test_a_logged_call_moves_the_kept_window
        ; test_case
            "a call before the window is not found"
            `Quick
            test_a_call_before_the_window_is_not_found
        ; test_case
            "a last row that is not JSON"
            `Quick
            test_a_last_row_that_is_not_json
        ; test_case
            "the window is kept beside the read index"
            `Quick
            test_the_window_is_kept_beside_the_read_index
        ; test_case
            "a ledger the strict read refuses is read leniently"
            `Quick
            test_a_ledger_the_strict_read_refuses_is_read_leniently
        ] )
    ]
;;
