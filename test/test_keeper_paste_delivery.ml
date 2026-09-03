(* Paste delivery to endpoint-owned keeper workspaces.

   The TUI stages a spilled paste as [pasted-*.txt] under the keeper's host
   bookkeeping bundle, and at turn setup [Keeper_paste_delivery] writes each
   staged file to the endpoint's workspace root and removes the staged copy.
   The transport is injected so the feature — select only staged pastes,
   deliver, keep evidence on failure — is exercised without a live endpoint:
   the production wiring ([deliver_for_turn]) supplies the remote-lane
   write. *)

open Alcotest
module Delivery = Masc.Keeper_paste_delivery

let with_staging_dir f =
  let dir = Filename.temp_dir "keeper-paste-delivery" "" in
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir dir
      |> Array.iter (fun name ->
           let path = Filename.concat dir name in
           if Sys.is_directory path then Unix.rmdir path else Sys.remove path);
      Unix.rmdir dir)
    (fun () -> f dir)
;;

let write_staged dir name content =
  let channel = open_out_bin (Filename.concat dir name) in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

(* A turn with pastes, notes, and a stray directory in the bundle delivers
   the pastes — contents intact, staged copies gone — and touches nothing
   else. *)
let test_delivers_only_staged_pastes () =
  with_staging_dir (fun dir ->
    write_staged dir "pasted-2026-09-03T10-00-00-a1b2.txt" "first paste body";
    write_staged dir "pasted-2026-09-03T11-00-00-c3d4.txt" "second paste body";
    write_staged dir "notes.txt" "not a paste";
    write_staged dir "pasted-notes.md" "not the staged suffix";
    Unix.mkdir (Filename.concat dir "pasted-2026-09-03T12-00-00-e5f6.txt") 0o755;
    let delivered = ref [] in
    let write ~file_name ~content =
      delivered := (file_name, content) :: !delivered;
      Ok ()
    in
    let outcomes = Delivery.deliver_staged_pastes ~write ~staging_dir:dir in
    let expected =
      [ "pasted-2026-09-03T10-00-00-a1b2.txt", "first paste body"
      ; "pasted-2026-09-03T11-00-00-c3d4.txt", "second paste body"
      ]
    in
    let delivered_names =
      List.filter_map
        (fun outcome ->
           match outcome with
           | Delivery.Delivered { file_name; bytes } ->
             check int "byte count is the staged content's"
               (String.length (List.assoc file_name expected))
               bytes;
             Some file_name
           | Delivery.Retained { file_name; _ } ->
             failf "%s stayed staged though the write succeeded" file_name)
        outcomes
    in
    check
      (list string)
      "exactly the two staged pastes delivered"
      (List.map fst expected)
      delivered_names;
    check
      (list (pair string string))
      "the transport saw the same two, with their contents"
      expected
      (List.sort compare !delivered);
    List.iter
      (fun file_name ->
        if Sys.file_exists (Filename.concat dir file_name)
        then failf "%s still staged after a successful delivery" file_name)
      delivered_names;
    check bool "unrelated file untouched" true
      (String.equal (read_file (Filename.concat dir "notes.txt")) "not a paste");
    check bool "wrong-suffix file untouched" true
      (Sys.file_exists (Filename.concat dir "pasted-notes.md"));
    check bool "same-named directory untouched" true
      (Sys.is_directory (Filename.concat dir "pasted-2026-09-03T12-00-00-e5f6.txt")))
;;

(* failure_keeps_evidence: a refused endpoint write leaves the staged file
   for the next turn, and the outcome says so. *)
let test_failed_write_retains_the_staged_paste () =
  with_staging_dir (fun dir ->
    write_staged dir "pasted-2026-09-03T10-00-00-a1b2.txt" "paste body";
    let write ~file_name:_ ~content:_ = Error "endpoint unreachable" in
    match Delivery.deliver_staged_pastes ~write ~staging_dir:dir with
    | [ Delivery.Retained { file_name; reason } ] ->
      check string "the retained file is the staged paste"
        "pasted-2026-09-03T10-00-00-a1b2.txt" file_name;
      (match reason with
       | Delivery.Remote_write_failed detail ->
         check string "the endpoint's answer is the retained evidence"
           "endpoint unreachable" detail
       | Delivery.Staging_read_failed _ ->
         fail "the staged file was readable; the endpoint refused the write");
      check bool "staged copy kept for the next turn" true
        (String.equal
           (read_file (Filename.concat dir file_name))
           "paste body")
    | outcomes ->
      failf "one refused write must retain one paste, got %d outcome(s)"
        (List.length outcomes))
;;

let () =
  run
    "keeper_paste_delivery"
    [ ( "staging"
      , [ test_case "delivers only staged pastes" `Quick test_delivers_only_staged_pastes
        ; test_case "failed write retains the staged paste" `Quick
            test_failed_write_retains_the_staged_paste
        ] )
    ]
;;
