(* One Keeper's Memory on disk (RFC librarian-call-only-proposes §8.2 steps
   2 to 5, §8.6): each row of the boot table, the chain of commits, and a
   snapshot that is one line behind its log. *)

open Alcotest
module Store = Masc.Librarian_store
module Envelope = Masc.Librarian_envelope
module Log = Masc.Librarian_log
module Log_codec = Masc.Librarian_log_codec
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Current = Masc.Keeper_memory_os_current_types
module Snapshot_codec = Masc.Keeper_memory_os_snapshot_codec
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
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

type place =
  { memory_dir : string
  ; turns_dir : string
  }

let new_place () =
  { memory_dir = Filename.temp_dir "memory" ""; turns_dir = Filename.temp_dir "turns" "" }
;;

let snapshot_path place =
  Masc.Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:place.memory_dir
    ~keeper_id
;;

let log_path place = Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id

let turn_log_path place =
  Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id
;;

let start_turn_log place =
  match
    Turn_store.append ~path:(turn_log_path place) ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

(* A place whose Keeper has a turn log and nothing else. *)
let started_place () =
  let place = new_place () in
  start_turn_log place;
  place
;;

let hex (digest : Digest.digest) = (digest :> string)
let file_bytes path = In_channel.with_open_bin path In_channel.input_all
let digest_of_file path = Digest.digest_of_bytes (file_bytes path)

let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let append_raw path text =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path (fun channel ->
    Out_channel.output_string channel text)
;;

let encoded line = Yojson.Safe.to_string (Log_codec.to_json line)
let claims (memory : Current.t) = List.map (fun (fact : Types.fact) -> fact.claim) memory.facts

let stop_text : Store.stop -> string = function
  | Log_diverged { expected; observed } ->
    Printf.sprintf "diverged: the log names %s and the file is %s" (hex expected) (hex observed)
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
;;

let boot ?(at = 100.0) place =
  Store.boot ~memory_dir:place.memory_dir ~turns_dir:place.turns_dir ~keeper_id ~at
;;

let booted ?at place =
  match boot ?at place with
  | Ok store -> store
  | Error stop -> fail ("boot: " ^ stop_text stop)
;;

let boot_text place =
  match boot place with
  | Ok (_ : Store.t) -> "booted"
  | Error stop -> stop_text stop
;;

let remember claim =
  Direct.Remember
    { claim; category = Types.Constraint; basis = Types.Observed Types.Transcript }
;;

let plan store ~at write =
  match Direct.plan ~by:Effects.Keeper ~at ~trace_id:"turn" (Store.memory store).facts write with
  | Writes { effects; facts = (_ : Types.fact list) } -> effects
  | Already_held | Already_done | Already_absent | Refused _ ->
    fail "the write of the fixture does not write"
;;

let commit store ~at write effects =
  Store.commit_direct store ~at ~by:Effects.Keeper ~trace:"turn" write effects
;;

let committed store ~at write =
  match commit store ~at write (plan store ~at write) with
  | Committed { store; line } -> store, line
  | Committed_without_snapshot (_ : Log.commit) -> fail "the snapshot was not written"
  | Stopped stop -> fail ("commit: " ^ stop_text stop)
  | Not_a_snapshot (_ : Envelope.refusal) -> fail "the effects do not make a snapshot"
;;

let port = "the port is 8935"
let owner = "the owner is the release team"

let test_first_boot_without_a_snapshot () =
  let place = started_place () in
  let store = booted place in
  let empty = Envelope.empty ~at:100.0 ~turn_log in
  check string "the Keeper gets the empty snapshot"
    (Snapshot_codec.snapshot_bytes empty)
    (file_bytes (snapshot_path place));
  check (list string) "Memory holds nothing" [] (claims (Store.memory store));
  (match Store.tail store with
   | Started { at; turn_log = named; snapshot; revision; turn_log_offset; covered } ->
     check (float 0.0) "written at boot" 100.0 at;
     check string "names the turn log"
       (Turn_log.Log_id.to_string turn_log)
       (Turn_log.Log_id.to_string named);
     check string "names the snapshot" (hex (Envelope.digest empty)) (hex snapshot);
     check int "and its revision" 1 revision;
     check int "reading starts where the turn log starts" 0 turn_log_offset;
     check int "at the mark the turn log started with" 4 covered.closed_messages
   | Committed (_ : Log.commit) -> fail "the first line is a commit");
  check string "the log is that one line"
    (encoded (Store.tail store) ^ "\n")
    (file_bytes (log_path place))
;;

let test_first_boot_with_a_snapshot () =
  let place = started_place () in
  (* A snapshot left by another store: one fact at revision 2. *)
  let scratch = started_place () in
  let (_ : Store.t), (_ : Log.commit) = committed (booted scratch) ~at:60.0 (remember port) in
  let left = file_bytes (snapshot_path scratch) in
  write_file (snapshot_path place) left;
  let store = booted place in
  check string "the file is not rewritten" left (file_bytes (snapshot_path place));
  check (list string) "Memory is what the file holds" [ port ] (claims (Store.memory store));
  match Store.tail store with
  | Started { snapshot; revision; _ } ->
    check string "the line names the bytes the file holds"
      (hex (Digest.digest_of_bytes left))
      (hex snapshot);
    check int "and their revision" 2 revision
  | Committed (_ : Log.commit) -> fail "the first line is a commit"
;;

let test_first_boot_that_cannot_start () =
  let unreadable = started_place () in
  write_file (snapshot_path unreadable) "not a snapshot";
  check string "a snapshot that is not one" "memory unreadable" (boot_text unreadable);
  check bool "no line is written" false (Sys.file_exists (log_path unreadable));
  let no_turn_log = new_place () in
  check string "no turn log" "store unwritable" (boot_text no_turn_log);
  check bool "no snapshot is written" false (Sys.file_exists (snapshot_path no_turn_log));
  check bool "and no line" false (Sys.file_exists (log_path no_turn_log));
  let headless = new_place () in
  Unix.mkdir (Filename.dirname (turn_log_path headless)) 0o700;
  write_file (turn_log_path headless) "not json\n";
  check string "a turn log that does not start with its start" "store unwritable"
    (boot_text headless);
  check bool "no snapshot is written for it either" false
    (Sys.file_exists (snapshot_path headless))
;;

let test_boot_twice () =
  let place = started_place () in
  let first = booted ~at:100.0 place in
  let log = file_bytes (log_path place) in
  let snapshot = file_bytes (snapshot_path place) in
  let second = booted ~at:300.0 place in
  check string "the second boot appends nothing" log (file_bytes (log_path place));
  check string "and rewrites nothing" snapshot (file_bytes (snapshot_path place));
  check string "it reads the line the first one wrote"
    (encoded (Store.tail first))
    (encoded (Store.tail second))
;;

let test_commits_chain () =
  let place = started_place () in
  let store = booted place in
  let started_on = digest_of_file (snapshot_path place) in
  let store, first = committed store ~at:201.0 (remember port) in
  check int "the first commit" 1 first.seq;
  check string "is committed on the snapshot the log started with" (hex started_on)
    (hex first.basis);
  check string "names the snapshot the file now holds"
    (hex (digest_of_file (snapshot_path place)))
    (hex first.after);
  check int "and its revision" 2 first.revision;
  check int "what was read has not moved" 0 first.turn_log_offset;
  check bool "nothing is read yet" true
    (match first.covers_through with
     | Before_first -> true
     | Through _ -> false);
  check (option string) "no working state yet" None first.working_state;
  check (list string) "Memory" [ port ] (claims (Store.memory store));
  let store, second = committed store ~at:202.0 (remember owner) in
  check int "the next commit" 2 second.seq;
  check string "is committed on the snapshot of the one before" (hex first.after)
    (hex second.basis);
  check int "one revision on" 3 second.revision;
  check (list string) "Memory" [ port; owner ] (claims (Store.memory store));
  check string "the log is the three lines"
    (String.concat ""
       (List.map
          (fun line -> encoded line ^ "\n")
          [ Log.Started
              { at = 100.0
              ; turn_log
              ; snapshot = started_on
              ; revision = 1
              ; turn_log_offset = 0
              ; covered = mark
              }
          ; Committed first
          ; Committed second
          ]))
    (file_bytes (log_path place));
  let again = booted place in
  check string "boot reads the last line" (encoded (Store.tail store)) (encoded (Store.tail again));
  check (list string) "and its Memory" [ port; owner ] (claims (Store.memory again))
;;

(* The line was appended and the process ended before the snapshot was
   written. *)
let test_snapshot_one_line_behind () =
  let place = started_place () in
  let store, (_ : Log.commit) = committed (booted place) ~at:201.0 (remember port) in
  let behind = file_bytes (snapshot_path place) in
  let (_ : Store.t), (_ : Log.commit) = committed store ~at:202.0 (remember owner) in
  let written = file_bytes (snapshot_path place) in
  let log = file_bytes (log_path place) in
  write_file (snapshot_path place) behind;
  let recovered = booted place in
  check string "boot writes the snapshot again from the line" written
    (file_bytes (snapshot_path place));
  check string "and appends nothing" log (file_bytes (log_path place));
  check (list string) "Memory is the line's" [ port; owner ] (claims (Store.memory recovered));
  let (_ : Store.t) = booted place in
  check string "a second recovery changes nothing" written (file_bytes (snapshot_path place))
;;

let test_snapshot_changed_from_outside () =
  let place = started_place () in
  let store, line = committed (booted place) ~at:201.0 (remember port) in
  let other = Snapshot_codec.snapshot_bytes (Envelope.empty ~at:999.0 ~turn_log) in
  write_file (snapshot_path place) other;
  let diverged =
    stop_text (Log_diverged { expected = line.after; observed = Digest.digest_of_bytes other })
  in
  let log = file_bytes (log_path place) in
  let write = remember owner in
  (match commit store ~at:202.0 write (plan store ~at:202.0 write) with
   | Stopped stop -> check string "a commit stops" diverged (stop_text stop)
   | Committed _ | Committed_without_snapshot _ | Not_a_snapshot _ ->
     fail "a commit went on over a snapshot it did not write");
  check string "and appends nothing" log (file_bytes (log_path place));
  check string "boot stops the same way" diverged (boot_text place);
  check string "and leaves the file" other (file_bytes (snapshot_path place))
;;

(* The last line was committed on the snapshot the file holds, and applying
   it does not give the snapshot it names. *)
let test_a_line_that_does_not_make_its_snapshot () =
  let place = started_place () in
  let store = booted place in
  let held = file_bytes (snapshot_path place) in
  let basis = Digest.digest_of_bytes held in
  let named = Digest.digest_of_bytes "another snapshot" in
  let line =
    Log.Committed
      { seq = 1
      ; at = 201.0
      ; basis
      ; after = named
      ; revision = 2
      ; cause = Direct { by = Keeper; trace = "turn"; write = remember port }
      ; effects = Effects.empty
      ; turn_log
      ; turn_log_offset = 0
      ; covers_through = Before_first
      ; covered = mark
      ; working_state = None
      }
  in
  append_raw (log_path place) (encoded line ^ "\n");
  check string "boot does not write bytes the line does not name"
    (stop_text (Log_diverged { expected = named; observed = basis }))
    (boot_text place);
  check string "the file is as it was" held (file_bytes (snapshot_path place));
  check (list string) "the store that was open held nothing" [] (claims (Store.memory store))
;;

let test_files_that_cannot_be_read () =
  let no_tail = started_place () in
  let (_ : Store.t) = booted no_tail in
  append_raw (log_path no_tail) "not json\n";
  check string "a last line that does not decode" "log unreadable" (boot_text no_tail);
  let no_snapshot = started_place () in
  let (_ : Store.t) = booted no_snapshot in
  Sys.remove (snapshot_path no_snapshot);
  check string "a log without its snapshot" "memory unreadable" (boot_text no_snapshot);
  check bool "the snapshot is not made again" false (Sys.file_exists (snapshot_path no_snapshot));
  let garbage = started_place () in
  let store = booted garbage in
  write_file (snapshot_path garbage) "not a snapshot";
  check string "a snapshot that is not one" "memory unreadable" (boot_text garbage);
  Sys.remove (snapshot_path garbage);
  let write = remember port in
  match commit store ~at:201.0 write (plan store ~at:201.0 write) with
  | Stopped stop ->
    check string "a commit without the snapshot file" "memory unreadable" (stop_text stop)
  | Committed _ | Committed_without_snapshot _ | Not_a_snapshot _ ->
    fail "a commit went on without the snapshot file"
;;

(* Another line was appended after the one the store read. *)
let test_log_moved_under_the_store () =
  let place = started_place () in
  let store = booted place in
  let held = digest_of_file (snapshot_path place) in
  let foreign =
    Log.Committed
      { seq = 1
      ; at = 150.0
      ; basis = held
      ; after = held
      ; revision = 1
      ; cause = Adopt { by = "operator-1"; observed = held }
      ; effects = Effects.empty
      ; turn_log
      ; turn_log_offset = 0
      ; covers_through = Before_first
      ; covered = mark
      ; working_state = None
      }
  in
  append_raw (log_path place) (encoded foreign ^ "\n");
  let log = file_bytes (log_path place) in
  let snapshot = file_bytes (snapshot_path place) in
  let write = remember port in
  (match commit store ~at:201.0 write (plan store ~at:201.0 write) with
   | Stopped stop ->
     check string "the commit stops"
       (stop_text (Log_diverged { expected = held; observed = held }))
       (stop_text stop)
   | Committed _ | Committed_without_snapshot _ | Not_a_snapshot _ ->
     fail "a commit went on after a line it did not read");
  check string "and appends nothing" log (file_bytes (log_path place));
  check string "and leaves the snapshot" snapshot (file_bytes (snapshot_path place))
;;

let test_effects_that_make_no_snapshot () =
  let place = started_place () in
  let store, (_ : Log.commit) = committed (booted place) ~at:201.0 (remember port) in
  let log = file_bytes (log_path place) in
  let held = List.hd (Store.memory store).facts in
  match
    commit store ~at:202.0 (remember port) { Effects.empty with added = [ held ] }
  with
  | Not_a_snapshot (Facts_inconsistent (_ : string)) ->
    check string "nothing is appended" log (file_bytes (log_path place))
  | Not_a_snapshot (Revision_not_next _ | Not_encodable _) -> fail "refused for another reason"
  | Committed _ | Committed_without_snapshot _ | Stopped _ ->
    fail "effects that hold one fact twice were committed"
;;

let adoption_text : (Store.t, Store.adoption_refusal) result -> string = function
  | Ok (_ : Store.t) -> "adopted"
  | Error Snapshot_mismatch -> "snapshot mismatch"
  | Error Snapshot_unreadable -> "snapshot unreadable"
  | Error (Not_adopted stop) -> "not adopted: " ^ stop_text stop
;;

let adopt ?(at = 400.0) place observed =
  Store.adopt ~memory_dir:place.memory_dir ~turns_dir:place.turns_dir ~keeper_id ~at
    ~by:"operator-1" ~observed
;;

(* A store with one commit whose snapshot was then replaced from outside by
   another snapshot. *)
let diverged_place () =
  let place = started_place () in
  let (_ : Store.t), line = committed (booted place) ~at:201.0 (remember port) in
  let other = Snapshot_codec.snapshot_bytes (Envelope.empty ~at:999.0 ~turn_log) in
  write_file (snapshot_path place) other;
  place, line, other
;;

let test_adopt_a_diverged_snapshot () =
  let place, before, other = diverged_place () in
  let observed = Digest.digest_of_bytes other in
  let store =
    match adopt place observed with
    | Ok store -> store
    | Error (_ : Store.adoption_refusal) as refused -> fail (adoption_text refused)
  in
  check string "the file is not written" other (file_bytes (snapshot_path place));
  check (list string) "Memory is what the file holds" [] (claims (Store.memory store));
  (match Store.tail store with
   | Committed line ->
     check int "the commit after the last one" (before.seq + 1) line.seq;
     check string "committed on the snapshot the last line named" (hex before.after)
       (hex line.basis);
     check string "it names the bytes the operator named" (hex observed) (hex line.after);
     check int "and their revision" 1 line.revision;
     check int "reading goes on where it was" before.turn_log_offset line.turn_log_offset;
     check string "the cause is the adoption" "operator-1"
       (match line.cause with
        | Adopt { by; observed = (_ : Digest.digest) } -> by
        | Direct _ -> "a direct write")
   | Started _ -> fail "a log whose last line decodes was started over");
  check string "boot now opens the store" "booted" (boot_text place);
  let (_ : Store.t), next = committed store ~at:401.0 (remember owner) in
  check int "the next commit follows the adoption" (before.seq + 2) next.seq;
  check string "and is committed on the adopted bytes" (hex observed) (hex next.basis)
;;

let test_adopt_refuses () =
  let place, (_ : Log.commit), other = diverged_place () in
  let log = file_bytes (log_path place) in
  check string "bytes the file does not hold" "snapshot mismatch"
    (adoption_text (adopt place (Digest.digest_of_bytes "another snapshot")));
  write_file (snapshot_path place) "not a snapshot";
  check string "bytes that are not a snapshot" "snapshot unreadable"
    (adoption_text (adopt place (Digest.digest_of_bytes "not a snapshot")));
  Sys.remove (snapshot_path place);
  check string "no file" "snapshot mismatch"
    (adoption_text (adopt place (Digest.digest_of_bytes other)));
  check string "nothing was appended" log (file_bytes (log_path place))
;;

(* A link to itself where the snapshot belongs: opening it fails for every
   user, and that is not "no snapshot". *)
let link_to_itself path =
  if Sys.file_exists path then Sys.remove path;
  Unix.symlink (Filename.basename path) path
;;

let test_a_snapshot_whose_read_fails () =
  let at_first_boot = started_place () in
  link_to_itself (snapshot_path at_first_boot);
  check string "the first boot" "store unwritable" (boot_text at_first_boot);
  check bool "no commit log was started" false (Sys.file_exists (log_path at_first_boot));
  let later = started_place () in
  let store = booted later in
  link_to_itself (snapshot_path later);
  check string "a later boot" "store unwritable" (boot_text later);
  let write = remember port in
  (match commit store ~at:201.0 write (plan store ~at:201.0 write) with
   | Stopped stop -> check string "a commit" "store unwritable" (stop_text stop)
   | Committed _ | Committed_without_snapshot _ | Not_a_snapshot _ ->
     fail "a commit went on without reading the snapshot");
  let log = file_bytes (log_path later) in
  check string "an adoption" "not adopted: store unwritable"
    (adoption_text (adopt later (Digest.digest_of_bytes "any bytes")));
  check string "nothing was appended" log (file_bytes (log_path later))
;;

(* The last line does not decode, so where reading had reached is lost. *)
let test_adopt_after_an_unreadable_tail () =
  let place = started_place () in
  let (_ : Store.t), (_ : Log.commit) = committed (booted place) ~at:201.0 (remember port) in
  append_raw (log_path place) "not json\n";
  let log = file_bytes (log_path place) in
  let held = file_bytes (snapshot_path place) in
  let observed = Digest.digest_of_bytes held in
  let store =
    match adopt place observed with
    | Ok store -> store
    | Error (_ : Store.adoption_refusal) as refused -> fail (adoption_text refused)
  in
  (match Store.tail store with
   | Started { at; snapshot; revision; turn_log_offset; covered; turn_log = (_ : Turn_log.Log_id.t) }
     ->
     check (float 0.0) "written when adopted" 400.0 at;
     check string "it names the bytes the operator named" (hex observed) (hex snapshot);
     check int "and their revision" 2 revision;
     check int "reading starts over" 0 turn_log_offset;
     check int "at the mark the turn log started with" 4 covered.closed_messages
   | Committed (_ : Log.commit) -> fail "reading went on from a line that was not read");
  check string "the line follows the one that does not decode"
    (log ^ encoded (Store.tail store) ^ "\n")
    (file_bytes (log_path place));
  check (list string) "Memory is what the file holds" [ port ] (claims (Store.memory store));
  check string "boot now opens the store" "booted" (boot_text place);
  let (_ : Store.t), next = committed store ~at:401.0 (remember owner) in
  check int "commits count from the new start" 1 next.seq;
  let no_turn_log = started_place () in
  let (_ : Store.t) = booted no_turn_log in
  append_raw (log_path no_turn_log) "not json\n";
  Sys.remove (turn_log_path no_turn_log);
  let log = file_bytes (log_path no_turn_log) in
  check string "without a turn log there is nothing to start over from"
    "not adopted: store unwritable"
    (adoption_text (adopt no_turn_log (digest_of_file (snapshot_path no_turn_log))));
  check string "and nothing is appended" log (file_bytes (log_path no_turn_log))
;;

let () =
  run "librarian_store"
    [ ( "first boot"
      , [ test_case "a Keeper without a snapshot" `Quick test_first_boot_without_a_snapshot
        ; test_case "a Keeper with a snapshot" `Quick test_first_boot_with_a_snapshot
        ; test_case "what cannot start" `Quick test_first_boot_that_cannot_start
        ; test_case "twice" `Quick test_boot_twice
        ] )
    ; ( "commit"
      , [ test_case "commits chain" `Quick test_commits_chain
        ; test_case "effects that make no snapshot" `Quick test_effects_that_make_no_snapshot
        ; test_case "the log moved under the store" `Quick test_log_moved_under_the_store
        ] )
    ; ( "recovery"
      , [ test_case "a snapshot one line behind" `Quick test_snapshot_one_line_behind
        ; test_case "a snapshot changed from outside" `Quick test_snapshot_changed_from_outside
        ; test_case "a line that does not make its snapshot" `Quick
            test_a_line_that_does_not_make_its_snapshot
        ; test_case "files that cannot be read" `Quick test_files_that_cannot_be_read
        ] )
    ; ( "adopt"
      , [ test_case "a diverged snapshot" `Quick test_adopt_a_diverged_snapshot
        ; test_case "what is refused" `Quick test_adopt_refuses
        ; test_case "a snapshot whose read fails" `Quick test_a_snapshot_whose_read_fails
        ; test_case "after a last line that does not decode" `Quick
            test_adopt_after_an_unreadable_tail
        ] )
    ]
;;
