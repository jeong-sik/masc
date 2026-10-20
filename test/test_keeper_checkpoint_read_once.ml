(** What the checkpoint store reads from the canonical file, and when it
    answers without reading it. The locked read takes the whole file into one
    allocation of its size and keeps the answers of the read it replaced: the
    same bytes and digest, and the same refusals for a missing, symlinked,
    unreadable or truncated canonical. *)

open Alcotest
open Masc
module Store = Keeper_checkpoint_store

let history_retained () =
  Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained

let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages =
    [ Agent_core.Types.
        { role = User; content = [ Text "hello" ]; name = None; tool_call_id = None
        ; metadata = [] }
    ; Agent_core.Types.
        { role = Assistant; content = [ Text marker ]; name = None
        ; tool_call_id = None; metadata = [] }
    ]
  in
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id
    ; agent_name = "agent_core-test-runtime"
    ; model = "test-model"
    ; system_prompt = None
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count
    ; created_at = 1000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None
    ; mcp_sessions = []
    ; working_context = None
    }

(* Larger than one [Unix.read], which moves at most 64 KB a call. *)
let several_reads_marker = String.make 300_000 'm'

let with_session f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let root = Filename.temp_file "keeper-checkpoint-read-once" "" in
    Unix.unlink root;
    Unix.mkdir root 0o700;
    let session_dir = Filename.concat root "session" in
    Unix.mkdir session_dir 0o700;
    let rec remove path =
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Unix.chmod path 0o700;
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Unix.unlink path
    in
    Fun.protect ~finally:(fun () -> remove root) (fun () -> f session_dir))

let canonical_path session_dir = Store.agent_core_checkpoint_path ~session_dir ~session_id:"session"
let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path bytes = Out_channel.with_open_bin path (fun ch -> output_string ch bytes)
let one_shot_sha256 bytes = Digestif.SHA256.(to_hex (digest_string bytes))

let save_plain ~session_dir checkpoint =
  match Store.save_agent_core_classified ~history_retained:(history_retained ()) ~session_dir checkpoint with
  | Ok _ -> ()
  | Error error -> fail ("save failed: " ^ error)

let load_snapshot ~session_dir label =
  match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:"session" with
  | Ok snapshot -> snapshot
  | Error error -> failf "%s: %s" label (Store.checkpoint_ref_load_error_to_string error)

let refused_as label expected session_dir =
  match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:"session", expected with
  | Error Store.Ref_not_found, `Absent
  | Error (Store.Ref_read_failed (Store.Io_error _)), `Io_error
  | Error (Store.Ref_read_failed (Store.Parse_error _)), `Parse_error -> ()
  | Error error, _ -> failf "%s: refused as %s" label (Store.checkpoint_ref_load_error_to_string error)
  | Ok _, _ -> failf "%s: the canonical was accepted" label

let test_the_snapshot_holds_the_file_bytes_and_their_digest () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:4 ~marker:several_reads_marker);
  let on_disk = read_file (canonical_path session_dir) in
  let snapshot = load_snapshot ~session_dir "the canonical did not load" in
  check bool "the file takes more than one read" true (String.length on_disk > 65_536);
  check string "the snapshot holds the file's bytes" on_disk (Store.exact_snapshot_canonical_bytes snapshot);
  check string "the reference is the digest of those bytes" (one_shot_sha256 on_disk)
    (Store.exact_snapshot_reference snapshot).sha256;
  check int "the reference carries the file's turn" 4 (Store.exact_snapshot_reference snapshot).turn_count)

let test_a_missing_canonical_is_absent () = with_session (fun session_dir ->
  refused_as "a missing canonical" `Absent session_dir)

let test_a_symlinked_canonical_is_refused () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"linked");
  let path = canonical_path session_dir in
  let target = Filename.concat (Filename.dirname session_dir) "outside.json" in
  write_file target (read_file path);
  Sys.remove path;
  Unix.symlink target path;
  refused_as "a symlinked canonical" `Io_error session_dir)

let test_a_directory_at_the_canonical_path_is_refused () = with_session (fun session_dir ->
  Unix.mkdir (canonical_path session_dir) 0o700;
  refused_as "a directory canonical" `Io_error session_dir)

let test_an_unreadable_canonical_is_refused () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:"unreadable");
  let path = canonical_path session_dir in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o600) (fun () ->
    refused_as "an unreadable canonical" `Io_error session_dir))

let test_a_truncated_canonical_is_a_parse_error () = with_session (fun session_dir ->
  save_plain ~session_dir (make_checkpoint ~session_id:"session" ~turn_count:1 ~marker:several_reads_marker);
  let path = canonical_path session_dir in
  let bytes = read_file path in
  write_file path (String.sub bytes 0 (String.length bytes / 2));
  refused_as "a truncated canonical" `Parse_error session_dir;
  write_file path "";
  refused_as "an empty canonical" `Parse_error session_dir)

let () =
  run "keeper checkpoint read once"
    [ ( "locked read"
      , [ test_case "the snapshot holds the file's bytes and their digest" `Quick
            test_the_snapshot_holds_the_file_bytes_and_their_digest
        ; test_case "a missing canonical is absent" `Quick test_a_missing_canonical_is_absent
        ; test_case "a symlinked canonical is refused" `Quick test_a_symlinked_canonical_is_refused
        ; test_case "a directory at the canonical path is refused" `Quick
            test_a_directory_at_the_canonical_path_is_refused
        ; test_case "an unreadable canonical is refused" `Quick test_an_unreadable_canonical_is_refused
        ; test_case "a truncated canonical is a parse error" `Quick
            test_a_truncated_canonical_is_a_parse_error
        ] )
    ]
