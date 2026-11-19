(** [masc_checkpoint_purge] — offline deterministic checkpoint purge
    (RFC-0351 S1).

    Loads the canonical AGENT_CORE checkpoint for one trace, applies
    {!Masc.Keeper_checkpoint_purge.purge} (unsigned reasoning strip and
    tool-result content clear, neither of which removes an atom — no LLM
    involved), and prints a per-rule report. Dry-run by default; [--apply] backs
    the head and its objects up, then installs the purged checkpoint with
    [Keeper_checkpoint_store.save_agent_core_if_source]: only over the head it
    read, and with every message closed. It then deletes the session's history
    archive entries, which are heads of the checkpoint before the purge.

    Run [--apply] only while the keeper is stopped ([masc_keeper_down]): a
    live keeper holds the conversation in memory and its next save overwrites
    the purge. Before it reads the head, [--apply] takes the workspace writer
    lease that the server holds while it runs, so it is refused while a server
    owns the workspace: that server's Librarian lane would read the position
    and the checkpoint while they are replaced. On the server, the dashboard purge action cancels and
    awaits that lane instead.

    A purge that drops what follows a break shrinks the head, so it goes
    through {!Masc.Keeper_turn_log_reset.run} (RFC
    librarian-call-only-proposes §5.2, §5.6): the open messages are closed and
    the Keeper's turn log line names what is dropped before the purged head is
    installed. A line that is not written leaves everything as it was.

    The Librarian's atom position moves with the checkpoint (RFC
    librarian-lifecycle §10-2, {!Masc.Keeper_checkpoint_purge.librarian_rebase}):
    the rewrite is refused while the Librarian has atoms left to read, and
    otherwise the position is written after the checkpoint. The turn-boundary
    log and the saved Librarian working state are read first: the messages
    they name stay byte-exact, so both still match the purged checkpoint. *)

let usage =
  {|Usage: masc_checkpoint_purge --keeper NAME [OPTIONS]

Deterministic offline checkpoint purge (RFC-0351 S1). Dry-run by default.

Options:
  --keeper NAME            the keeper whose checkpoint is purged; its meta names
                           the trace, and its Librarian files are read and moved
  --trace ID               optional: refuse unless the keeper's meta names this trace
  --base DIR               workspace root (default: MASC_BASE_PATH or cwd)
  --apply                  back up, install the purged checkpoint over the head
                           it read, then delete the history archive entries of
                           the checkpoint before it
  --keep-recent N          protected tail length in messages (default 20)
  --no-strip-thinking      keep unsigned Thinking/ReasoningDetails blocks
  --no-clear-tool-results  keep ToolResult payloads
  -h, --help               print this help

The runtime root is {workspace}/.masc. Backups are stored in it.

--apply requires the keeper to be stopped (masc_keeper_down); a live keeper
overwrites the purge on its next save. It also requires that no server owns
the workspace (the writer lease); on a running server use the dashboard purge
action. A rewrite is refused while the Librarian has atoms of this checkpoint
left to read; otherwise the Librarian position is moved to the rewritten end
and written after the checkpoint. A purge that drops what follows a break
first writes the keeper's turn log line; when that line cannot be written
nothing is purged.

Exit codes:
  0  report printed (dry-run) or purge applied
  1  invalid argument / load / structural / save error
|}

module Purge = Masc.Keeper_checkpoint_purge
module Store = Masc.Keeper_checkpoint_store
module Progress = Masc.Keeper_librarian_progress

let error msg =
  prerr_endline msg;
  exit 1

let parse_positive_int_arg name raw =
  match int_of_string_opt (String.trim raw) with
  | Some n when n >= 0 -> n
  | _ -> error (Printf.sprintf "invalid %s: %S (expected an integer >= 0)" name raw)

let structural_error_text structural =
  Masc.Keeper_transcript_unit.show_structural_error structural

let purge_error_text = function
  | Purge.Invalid_config detail -> "invalid config: " ^ detail
  | Purge.Invalid_input_structure structural ->
    Printf.sprintf
      "checkpoint failed structural validation even with its break set aside, \
       and was not modified: %s"
      (structural_error_text structural)
  | Purge.Invalid_output_structure structural ->
    Printf.sprintf
      "purge produced an invalid structure — this is a bug in \
       keeper_checkpoint_purge, nothing was written: %s"
      (structural_error_text structural)
  | ( Purge.Repetition_boundary_invalid _
    | Purge.Atom_count_changed _
    | Purge.Kept_atom_rewritten _
    | Purge.Continuity_no_longer_fits _
    | Purge.Recovery_end_unwitnessed _ ) as purge_error ->
    Purge.purge_error_to_string purge_error

let timestamp_utc () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d%02d%02dT%02d%02d%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

type computed =
  { source_ref : Keeper_checkpoint_ref.t
  ; checkpoint : Agent_core.Checkpoint.t
  ; purged : Agent_core.Checkpoint.t
  ; report : Purge.report
  ; rebase : (Purge.rebase, Purge.refusal) result
  }

(* Every check before the turn log line ends the process instead. *)
type no_refusal = |

let with_apply_lease ~apply ~base_path f =
  if not apply
  then f ()
  else (
    let lease =
      match
        Server_startup_takeover.acquire_owner_lease
          (Host_config.host ()).base_path_lease_root base_path
      with
      | Server_startup_takeover.Base_path_acquired lease -> lease
      | Base_path_already_owned { owner; _ } ->
        error
          (Printf.sprintf
             "--apply refused: a server owns this workspace (pid %s); use the dashboard \
              purge action, which stops the keeper's Librarian lane for the rewrite"
             (match Server_startup_takeover.base_path_owner_pid owner with
              | Some pid -> string_of_int pid
              | None -> "unknown"))
      | Base_path_rejected rejection ->
        error
          ("--apply refused: workspace writer lease rejected: "
           ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection)
    in
    Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease) f)

let print_report ~keeper_name ~trace ~checkpoint_path computed =
  let report = computed.report in
  let before_len = String.length (Agent_core.Checkpoint.to_string computed.checkpoint) in
  let after_len = String.length (Agent_core.Checkpoint.to_string computed.purged) in
  Printf.printf "keeper: %s\n" keeper_name;
  Printf.printf "trace: %s\n" trace;
  Printf.printf "checkpoint: %s\n" checkpoint_path;
  Printf.printf "messages: %d -> %d\n" report.Purge.messages_before report.Purge.messages_after;
  Printf.printf
    "bytes (checkpoint JSON): %d -> %d (%+.1f%%)\n"
    before_len
    after_len
    (if before_len = 0
     then 0.0
     else
       100.0
       *. (float_of_int after_len -. float_of_int before_len)
       /. float_of_int before_len);
  Printf.printf "reasoning blocks stripped: %d\n" report.Purge.reasoning_blocks_stripped;
  Printf.printf "tool results cleared: %d\n" report.Purge.tool_results_cleared;
  Printf.printf
    "messages dropped at structural break: %d\n"
    report.Purge.messages_dropped_at_structural_break;
  match computed.rebase with
  | Ok Purge.No_progress -> print_endline "librarian position: none"
  | Ok (Purge.Rebased { before; after }) ->
    Printf.printf
      "librarian position: end_atom %d -> %d\n"
      before.Progress.position.end_atom
      after.Progress.position.end_atom
  | Error refusal ->
    Printf.printf "librarian position: apply refused: %s\n" (Purge.refusal_to_string refusal)

let install ~session_dir ~trace ~runtime_root ~runtime_keepers_dir ~keeper_name computed rebase =
  let backup_dir =
    Filename.concat
      runtime_root
      (Printf.sprintf "backups-checkpoint-purge-%s-%s" trace (timestamp_utc ()))
  in
  (* The head and the objects it names, as the session holds them: copying
     the directory over the session dir puts the checkpoint back. *)
  (match
     Store.back_up_canonical
       ~session_dir
       ~session_id:trace
       ~ownership_root:runtime_root
       ~backup_dir
       ~content:computed.source_ref.sha256
   with
   | Error (Store.Backup_content_changed _ as changed) ->
     error
       ("the checkpoint changed underneath the purge; re-run against the current file: "
        ^ Store.backup_error_to_string changed)
   | Error
       (( Store.Backup_canonical_unreadable _ | Store.Backup_canonical_absent
        | Store.Backup_object_unreadable _ | Store.Backup_file_conflict _
        | Store.Backup_write_failed _ | Store.Backup_read_back_mismatch _ ) as failure) ->
     error ("backup failed, nothing purged: " ^ Store.backup_error_to_string failure)
   | Ok backup ->
     Printf.printf "backup: %s (%d bytes with its objects)\n" backup_dir backup.backup_bytes);
  (* Installed only over the head this purge read: a head another writer
     installed in between is kept, and the purge is refused. *)
  match
    Store.save_agent_core_if_source
      ~session_dir
      ~expected_source_ref:computed.source_ref
      ~boundary:Agent_core.Checkpoint_objects.Turn_closes
      computed.purged
  with
  | Store.Not_installed { cause = Store.Source_changed _; _ } ->
    error
      "the checkpoint changed underneath the purge; re-run against the current file \
       (backup retained)"
  | Store.Not_installed
      { cause =
          ( Store.Source_unavailable _ | Store.Candidate_identity_invalid _
          | Store.Candidate_session_mismatch _ | Store.Candidate_turn_regressed _
          | Store.Candidate_unencodable _ | Store.Candidate_content_mismatch _
          | Store.Objects_not_installed _ | Store.Commit_not_installed _ ) as cause
      ; _
      } -> error ("save failed (backup retained): " ^ Store.checkpoint_cas_error_to_string cause)
  | Store.Installed installed ->
    Printf.printf
      "applied: purged checkpoint saved at turn_count %d\n"
      computed.purged.Agent_core.Checkpoint.turn_count;
    List.iter
      (fun auxiliary ->
         Printf.printf "warning: %s\n" (Store.checkpoint_installation_auxiliary_to_string auxiliary))
      installed.auxiliary;
    (* The archive entries are heads of the checkpoint before the purge;
       while one is there, the object sweep keeps what the purge removed
       (RFC-0476 §3.3). *)
    (match Store.delete_all_agent_core_history_files ~session_dir with
     | Error detail -> Printf.printf "warning: the history archive was not removed: %s\n" detail
     | Ok { removed; left } ->
       Printf.printf "applied: removed %d history archive entries\n" removed;
       List.iter (Printf.printf "warning: history archive entry kept: %s\n") left);
    (* The position follows the checkpoint. A failure here leaves the old
       position against the new numbering; the next Librarian round stops on
       the mismatch until the keeper's Librarian files are purged, and the
       message says so. *)
    (match rebase with
     | Purge.No_progress -> ()
     | Purge.Rebased { after; _ } ->
       (match Progress.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name after with
        | Ok () ->
          Printf.printf
            "applied: librarian position moved to end_atom %d\n"
            after.Progress.position.end_atom
        | Error write_error ->
          error
            ("checkpoint installed but the Librarian position was not moved with it; the \
              Librarian stops on the mismatch until the keeper's Librarian files are purged: "
             ^ Progress.write_error_to_string write_error)))

let () =
  let keeper = ref None in
  let trace_arg = ref None in
  let base = ref None in
  let apply = ref false in
  let config = ref Purge.default_config in
  let rec parse = function
    | [] -> ()
    | "-h" :: _ | "--help" :: _ ->
      print_string usage;
      exit 0
    | "--keeper" :: value :: rest ->
      keeper := Some value;
      parse rest
    | "--trace" :: value :: rest ->
      trace_arg := Some value;
      parse rest
    | "--base" :: value :: rest ->
      base := Some value;
      parse rest
    | "--apply" :: rest ->
      apply := true;
      parse rest
    | "--keep-recent" :: value :: rest ->
      config
      := { !config with
           Purge.keep_recent_messages = parse_positive_int_arg "--keep-recent" value
         };
      parse rest
    | "--no-strip-thinking" :: rest ->
      config := { !config with Purge.strip_thinking = false };
      parse rest
    | "--no-clear-tool-results" :: rest ->
      config := { !config with Purge.clear_tool_results = false };
      parse rest
    | unknown :: _ -> error (Printf.sprintf "unknown argument: %S\n%s" unknown usage)
  in
  parse (List.tl (Array.to_list Sys.argv));
  let keeper_name =
    match !keeper with
    | Some value when String.trim value <> "" -> value
    | Some _ | None -> error ("--keeper is required\n" ^ usage)
  in
  let base_path =
    (match !base with
     | Some value ->
       Masc.Workspace.Explicit (Config_dir_resolver.absolute_path value)
     | None ->
       Masc.Workspace.Explicit (Config_dir_resolver.base_path_or_cwd ()))
    |> Masc.Workspace.runtime_base_path
  in
  let session_store = Masc.Keeper_fs.session_store_path_for_base_path base_path in
  let runtime_root = Filename.dirname session_store in
  let runtime_keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  (* The keeper names the trace, as the dashboard purge does. A checkpoint's
     own [agent_name] is the agent-core agent's name, the runtime id, not the
     keeper, so nothing under keepers/<name>/ can be found from it (#37770).
     The read is the strict snapshot read: no storage backend, no repair. *)
  let trace =
    let path =
      Filename.concat
        runtime_keepers_dir
        (Keeper_runtime_root_entry.keeper_basename
           ~keeper_name Keeper_runtime_root_entry.Metadata)
    in
    match
      Masc.Keeper_meta_store.read_meta_file_path_read_only ~ownership_root:runtime_root path
    with
    | Error (Masc.Keeper_meta_store.Unreadable detail | Masc.Keeper_meta_store.Invalid_json detail) ->
      error ("keeper meta unreadable: " ^ detail)
    | Error (Masc.Keeper_meta_store.Not_current detail) ->
      error ("keeper meta is not the current schema: " ^ detail)
    | Ok None -> error ("no keeper named " ^ keeper_name ^ ": " ^ path ^ " does not exist")
    | Ok (Some meta) ->
      if not (String.equal meta.Masc.Keeper_meta_contract.name keeper_name)
      then error (path ^ " names keeper " ^ meta.Masc.Keeper_meta_contract.name);
      let trace =
        Keeper_id.Trace_id.to_string
          meta.Masc.Keeper_meta_contract.runtime.Masc.Keeper_meta_contract.trace_id
      in
      (match !trace_arg with
       | Some requested when not (String.equal (String.trim requested) trace) ->
         error
           (Printf.sprintf
              "keeper %s is on trace %s, not %s; nothing purged" keeper_name trace requested)
       | Some _ | None -> trace)
  in
  let session_dir = Filename.concat session_store trace in
  let checkpoint_path = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace in
  (* An apply holds the workspace writer lease from before it reads the head
     until it has installed (RFC librarian-call-only-proposes §5.6). *)
  with_apply_lease ~apply:!apply ~base_path
  @@ fun () ->
  if not (Sys.file_exists checkpoint_path)
  then error ("no canonical checkpoint at " ^ checkpoint_path);
  let compute () =
    match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:trace with
    | Error load_error -> error (Store.checkpoint_ref_load_error_to_string load_error)
    | Ok snapshot ->
      let source = Store.exact_snapshot_checkpoint snapshot in
      (* The purge works on its own context, so the snapshot still encodes to
         the content its reference names. *)
      let checkpoint =
        { source with Agent_core.Checkpoint.context = Agent_core.Context.copy source.context }
      in
      let boundary_lines =
        match
          Masc.Keeper_turn_boundaries.read
            ~keepers_dir:runtime_keepers_dir
            ~keeper_id:keeper_name
        with
        | Ok lines -> lines
        | Error detail -> error ("turn-boundary log unreadable: " ^ detail)
      in
      let continuity =
        match
          Masc.Keeper_librarian_continuity.read_in
            ~keepers_dir:runtime_keepers_dir
            ~keeper_name:keeper_name
        with
        | Ok continuity -> continuity
        | Error detail -> error ("Librarian working state unreadable: " ^ detail)
      in
      (* One read of the position serves both: a recovery ends the history
         where a line it counted states it, and the rebase moves it there. *)
      let progress =
        match Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name with
        | Ok progress -> progress
        | Error read_error ->
          error ("Librarian position unreadable: " ^ Progress.read_error_to_string read_error)
      in
      (match
         Purge.purge
           ~config:!config
           ~trace_id:trace
           ~boundary_lines
           ~continuity
           ~progress
           checkpoint
       with
       | Error purge_error -> error (purge_error_text purge_error)
       | Ok (purged, report) ->
         { source_ref = Store.exact_snapshot_reference snapshot
         ; checkpoint
         ; purged
         ; report
         ; rebase =
             Purge.librarian_rebase
               ~progress
               ~trace_id:trace
               ~before:checkpoint.messages
               ~after:purged.messages
         })
  in
  let print_report = print_report ~keeper_name ~trace ~checkpoint_path in
  if not !apply
  then (
    print_report (compute ());
    print_endline "dry-run: nothing written (pass --apply to persist)")
  else (
    let prepare () : (computed * Purge.rebase, no_refusal) result =
      let computed = compute () in
      match computed.rebase with
      | Ok rebase -> Ok (computed, rebase)
      | Error refusal ->
        print_report computed;
        error ("--apply refused: " ^ Purge.refusal_to_string refusal)
    in
    (* RFC librarian-call-only-proposes §5.2, §5.6: a purge that drops what
       follows a break shrinks the head, so the open messages are closed and
       the turn log line names what is dropped before the purged head goes
       in, with every message it keeps closed. A purge that only rewrites
       drops nothing and writes no line. *)
    let line ((computed : computed), (_ : Purge.rebase)) : Masc.Keeper_turn_log_reset.line =
      if computed.report.Purge.messages_dropped_at_structural_break > 0
      then
        Announce
          { cause = Recovered
          ; after =
              (fun mark ->
                 { mark with closed_messages = List.length computed.purged.messages })
          }
      else No_line
    in
    let change (computed, rebase) =
      print_report computed;
      install ~session_dir ~trace ~runtime_root ~runtime_keepers_dir ~keeper_name computed rebase
    in
    let place : Masc.Keeper_turn_log_recorder.place =
      { keepers_dir = runtime_keepers_dir
      ; base_path
      ; keeper_name
      ; session_dir
      ; session_id = trace
      }
    in
    match
      Masc.Keeper_turn_log_reset.run
        ~at:(Unix.gettimeofday ())
        ~new_log_id:(Masc.Keeper_turn_log.Log_id.fresh ())
        place
        ~prepare
        ~line
        ~change
    with
    | Ok () -> ()
    | Error (Path_refused (_ : no_refusal)) -> .
    | Error ((Open_not_closed _ | Line_not_written _ | Line_not_planned) as refusal) ->
      error
        ("--apply refused, nothing purged: the Keeper's turn log line was not written: "
         ^ Masc.Keeper_turn_log_reset.refusal_to_string (function (_ : no_refusal) -> .) refusal))
