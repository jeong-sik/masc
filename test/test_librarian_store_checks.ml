(* What the deploy check and the blob sweep make of a Keeper's turn log and
   Memory commit log (RFC librarian-call-only-proposes §20): both read the
   files before the first build that writes them. *)

open Alcotest
module D = Masc.Keeper_durable_store
module Writer = Masc.Librarian_writer
module Machine = Masc.Librarian_machine
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Digest = Agent_core.Checkpoint_objects

let keeper_id = "keeper-a"

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let private_dir path =
  Fs_compat.mkdir_p path;
  Unix.chmod path 0o700
;;

(* A workspace with the directories a server keeps Memory and turn logs in,
   and no Keeper yet. The configuration directory is named for the length of
   the case: one a shell exported would otherwise be the Memory directory. *)
let with_workspace body =
  let base_path = Unix.realpath (Filename.temp_dir "librarian-store-checks" "") in
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let config_root = Filename.concat masc_dir Config_dir_resolver.config_dirname in
  private_dir masc_dir;
  private_dir config_root;
  Masc_test_deps.with_process_env "MASC_CONFIG_DIR" (Some config_root) (fun () ->
    let place : Machine.place =
      { memory_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path
      ; turns_dir = Common.keepers_runtime_dir_of_base ~base_path
      ; keeper_id
      }
    in
    private_dir place.memory_dir;
    private_dir place.turns_dir;
    body ~base_path place)
;;

let turn_log_path (place : Machine.place) =
  Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let snapshot_path (place : Machine.place) =
  Masc.Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:place.memory_dir
    ~keeper_id
;;

let start_turn_log place =
  match
    Turn_store.append ~path:(turn_log_path place) ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

let file_bytes path = In_channel.with_open_bin path In_channel.input_all

let append_raw path text =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path (fun channel ->
    Out_channel.output_string channel text)
;;

let remember claim =
  Direct.Remember { claim; category = Types.Constraint; basis = Types.Observed Types.Transcript }
;;

(* What the deploy check says of one store: rows read, rows refused, and the
   first refusal. *)
let checked id ~base_path =
  match D.preflight_scan id with
  | None -> fail "the deploy check does not read the store"
  | Some scan ->
    (match D.run scan ~base_path with
     | Ok (report : D.report) -> (report.rows, report.refused), report.first_refusal
     | Error detail -> failf "the scan failed: %s" detail)
;;

let outcome = pair (pair int int) (option string)

let test_turn_log () =
  with_workspace
  @@ fun ~base_path place ->
  check outcome "no turn log is no line" ((0, 0), None) (checked D.Id.Turn_log ~base_path);
  start_turn_log place;
  check outcome "the line that starts the log" ((1, 0), None)
    (checked D.Id.Turn_log ~base_path);
  let path = turn_log_path place in
  let at = String.length (file_bytes path) in
  append_raw path "not json\n";
  append_raw path {|{"line":|};
  check outcome
    "a line that does not decode is refused where it starts; an append that was cut short is \
     not a line"
    ((2, 1), Some (Printf.sprintf "%s offset %d: not JSON" keeper_id at))
    (checked D.Id.Turn_log ~base_path)
;;

let test_memory_log () =
  with_workspace
  @@ fun ~base_path place ->
  start_turn_log place;
  check outcome "no commit log is no line" ((0, 0), None) (checked D.Id.Memory_log ~base_path);
  let booted ~at = Machine.booted place ~at ~lane:None ~last_ask:0 (Machine.boot place ~at) in
  (match
     Machine.write place (booted ~at:100.0) ~at:201.0 ~by:Effects.Keeper ~trace:"turn"
       (remember "the port is 8935")
   with
   | (_ : Machine.t), Written (_ : Masc.Librarian_log.commit) -> ()
   | ( (_ : Machine.t)
     , (Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _)
     ) -> fail "the write of the fixture was not committed");
  check outcome "the line that starts the log and one commit" ((2, 0), None)
    (checked D.Id.Memory_log ~base_path);
  let path = log_path place in
  let commit_text =
    match String.split_on_char '\n' (file_bytes path) with
    | [ (_ : string); commit; "" ] -> commit
    | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ -> fail "the commit log of the fixture is not two lines"
  in
  let tail_at = String.length (file_bytes path) in
  append_raw path "not json\n";
  check outcome "a last line that does not decode is refused where it starts"
    ((3, 1), Some (Printf.sprintf "%s offset %d: not JSON" keeper_id tail_at))
    (checked D.Id.Memory_log ~base_path);
  (match
     Machine.adopt place (booted ~at:300.0) ~at:301.0 ~by:"operator-1"
       ~observed:(Digest.digest_of_bytes (file_bytes (snapshot_path place)))
   with
   | (_ : Machine.t), Done -> ()
   | (_ : Machine.t), Not_done (_ : Machine.act_refusal) ->
     fail "the snapshot of the fixture was not adopted");
  check outcome "the tail an operator adopted past stays in the file and is a row"
    ((4, 0), None)
    (checked D.Id.Memory_log ~base_path);
  let middle_at = String.length (file_bytes path) in
  append_raw path ("{\"line\":\"finished\"}\n" ^ commit_text ^ "\n");
  check outcome "a line that does not decode with a commit after it is refused"
    ( (6, 1)
    , Some
        (Printf.sprintf "%s offset %d: %s" keeper_id middle_at
           (Types.wire_error_to_string
              { path = [ Wire_field "line" ]; reason = Unknown_token "finished" })) )
    (checked D.Id.Memory_log ~base_path)
;;

(* The sweep deletes nothing while a name in the Memory directory has no
   rule. A writer that has committed leaves its lock and the commit log
   there. *)
let test_the_blob_sweep_has_a_rule_for_each_file () =
  with_workspace
  @@ fun ~base_path place ->
  start_turn_log place;
  Eio_main.run (fun (_ : Eio_unix.Stdenv.base) ->
    Eio.Switch.run (fun sw ->
      let writer =
        Writer.create ~now:(fun () -> 200.0) ~registered:(fun () -> true)
          ~declared:(fun () -> None) ~stores:(Masc_test_deps.stores_of_place place)
          ~ask:Masc_test_deps.never_asks ~ask_room:Masc_test_deps.never_makes_room
          ~start_turn_log:(fun () -> Ok ()) place
      in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Writer.run writer;
        `Stop_daemon);
      match
        Writer.write writer ~by:Effects.Keeper ~trace:"turn" (remember "the port is 8935")
      with
      | Answered (Written (_ : Masc.Librarian_log.commit)) -> ()
      | Answered
          (Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _)
      | Ended -> fail "the write of the fixture was not committed"));
  check bool "the commit log is there" true (Sys.file_exists (log_path place));
  check bool "the writer's lock is there" true
    (Sys.file_exists (Filename.concat place.memory_dir (keeper_id ^ Writer.lock_suffix)));
  let (Tool_output.Stored (_ : Tool_output.artifact_ref)) =
    Tool_blob_store.put (Tool_blob_store.create ~base_path) ~bytes:"an output" ~mime:"text/plain"
  in
  match Tool_blob_sweep.observe ~base_path ~scope:Server_tool_blob_scope.scope with
  | Ok report -> check (list string) "every name has a rule" [] report.unclassified
  | Error error -> failf "the sweep failed: %s" (Tool_blob_sweep.error_to_string error)
;;

let () =
  run "librarian_store_checks"
    [ ( "deploy check"
      , [ test_case "the turn log" `Quick test_turn_log
        ; test_case "the Memory commit log" `Quick test_memory_log
        ] )
    ; ( "blob sweep"
      , [ test_case "a rule for each file" `Quick test_the_blob_sweep_has_a_rule_for_each_file ] )
    ]
;;
