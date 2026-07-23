(** [masc_checkpoint_purge] — offline deterministic checkpoint purge
    (RFC-0351 S1).

    Loads the canonical OAS checkpoint for one trace, applies
    {!Masc.Keeper_checkpoint_purge.purge} (duplicate collapse, unsigned
    reasoning strip, tool-result content clear — no LLM involved), and prints
    a per-rule report. Dry-run by default; [--apply] backs the original file
    up byte-exact and saves the purged checkpoint through
    [Keeper_checkpoint_store.save_oas_classified] (locked, structure-validated,
    watermark-checked; [turn_count] is unchanged so the save lands as an
    equal-watermark re-save).

    Run [--apply] only while the keeper is stopped ([masc_keeper_down]): a
    live keeper holds the conversation in memory and its next save overwrites
    the purge. *)

let usage =
  {|Usage: masc_checkpoint_purge --trace TRACE_ID [OPTIONS]

Deterministic offline checkpoint purge (RFC-0351 S1). Dry-run by default.

Options:
  --trace ID               trace/session id (directory under {base}/traces/)
  --base DIR               masc base dir (default: MASC_BASE_PATH or cwd)
  --apply                  back up, then write the purged checkpoint
  --keep-recent N          protected tail length in messages (default 20)
  --dup-threshold N        duplicate collapse threshold (default 3, >= 2)
  --no-strip-thinking      keep unsigned Thinking/ReasoningDetails blocks
  --no-clear-tool-results  keep ToolResult payloads
  -h, --help               print this help

--apply requires the keeper to be stopped (masc_keeper_down); a live keeper
overwrites the purge on its next save.

Exit codes:
  0  report printed (dry-run) or purge applied
  1  invalid argument / load / structural / save error
|}

module Purge = Masc.Keeper_checkpoint_purge
module Store = Masc.Keeper_checkpoint_store

let error msg =
  prerr_endline msg;
  exit 1

let parse_positive_int_arg name raw =
  match int_of_string_opt (String.trim raw) with
  | Some n when n >= 0 -> n
  | _ -> error (Printf.sprintf "invalid %s: %S (expected an integer >= 0)" name raw)

let structural_error_text structural =
  Masc.Keeper_compaction_unit.show_structural_error structural

let purge_error_text = function
  | Purge.Invalid_config detail -> "invalid config: " ^ detail
  | Purge.Invalid_input_structure structural ->
    Printf.sprintf
      "checkpoint failed structural validation and was not modified: %s\n\
       (a broken history has to be repaired at the write boundary that \
       admitted it, not by this tool — see #25443)"
      (structural_error_text structural)
  | Purge.Invalid_output_structure structural ->
    Printf.sprintf
      "purge produced an invalid structure — this is a bug in \
       keeper_checkpoint_purge, nothing was written: %s"
      (structural_error_text structural)

let load_error_text = function
  | Store.Not_found -> "canonical checkpoint file not found"
  | Store.Store_error detail -> "store error: " ^ detail
  | Store.Parse_error detail -> "parse error: " ^ detail
  | Store.Io_error detail -> "io error: " ^ detail
  | Store.Sdk_other_error detail -> "sdk error: " ^ detail

let read_file_bytes path =
  match In_channel.with_open_bin path In_channel.input_all with
  | bytes -> bytes
  | exception Sys_error detail -> error ("cannot read " ^ path ^ ": " ^ detail)

let write_file_bytes path bytes =
  match Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes) with
  | () -> ()
  | exception Sys_error detail -> error ("cannot write " ^ path ^ ": " ^ detail)

let timestamp_utc () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d%02d%02dT%02d%02d%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let () =
  let trace = ref None in
  let base = ref None in
  let apply = ref false in
  let config = ref Purge.default_config in
  let rec parse = function
    | [] -> ()
    | "-h" :: _ | "--help" :: _ ->
      print_string usage;
      exit 0
    | "--trace" :: value :: rest ->
      trace := Some value;
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
    | "--dup-threshold" :: value :: rest ->
      config
      := { !config with
           Purge.dup_threshold = parse_positive_int_arg "--dup-threshold" value
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
  let trace =
    match !trace with
    | Some value when String.trim value <> "" -> value
    | Some _ | None -> error ("--trace is required\n" ^ usage)
  in
  let base_path =
    match !base with
    | Some value -> Config_dir_resolver.absolute_path value
    | None -> Config_dir_resolver.base_path_or_cwd ()
  in
  let session_dir = Filename.concat (Filename.concat base_path "traces") trace in
  let checkpoint_path = Store.oas_checkpoint_path ~session_dir ~session_id:trace in
  if not (Sys.file_exists checkpoint_path)
  then error ("no canonical checkpoint at " ^ checkpoint_path);
  let original_bytes = read_file_bytes checkpoint_path in
  match Store.load_oas ~session_dir ~session_id:trace with
  | Error load_error -> error (load_error_text load_error)
  | Ok checkpoint ->
    (match Purge.purge ~config:!config checkpoint with
     | Error purge_error -> error (purge_error_text purge_error)
     | Ok (purged, report) ->
       let purged_bytes = Agent_sdk.Checkpoint.to_string purged in
       let before_len = String.length original_bytes in
       let after_len = String.length purged_bytes in
       Printf.printf "trace: %s\n" trace;
       Printf.printf "checkpoint: %s\n" checkpoint_path;
       Printf.printf
         "messages: %d -> %d\n"
         report.Purge.messages_before
         report.Purge.messages_after;
       Printf.printf
         "bytes (canonical): %d -> %d (%+.1f%%)\n"
         before_len
         after_len
         (if before_len = 0
          then 0.0
          else
            100.0
            *. (float_of_int after_len -. float_of_int before_len)
            /. float_of_int before_len);
       Printf.printf
         "R1 duplicate messages dropped: %d\n"
         report.Purge.duplicates_dropped;
       Printf.printf
         "R2 reasoning blocks stripped: %d (messages dropped when emptied: %d)\n"
         report.Purge.reasoning_blocks_stripped
         report.Purge.reasoning_messages_dropped;
       Printf.printf
         "R3 tool results cleared: %d\n"
         report.Purge.tool_results_cleared;
       if not !apply
       then print_endline "dry-run: nothing written (pass --apply to persist)"
       else (
         let backup_dir =
           Filename.concat
             base_path
             (Printf.sprintf "backups-checkpoint-purge-%s-%s" trace (timestamp_utc ()))
         in
         (match Sys.is_directory backup_dir with
          | true -> ()
          | false -> error (backup_dir ^ " exists and is not a directory")
          | exception Sys_error _ -> Unix.mkdir backup_dir 0o755);
         let backup_path = Filename.concat backup_dir (trace ^ ".json") in
         write_file_bytes backup_path original_bytes;
         Printf.printf "backup: %s (%d bytes)\n" backup_path before_len;
         (match Store.save_oas_classified ~session_dir purged with
          | Error detail -> error ("save failed (backup retained): " ^ detail)
          | Ok (Store.Stale_noop { incoming_turn_count; known_turn_count }) ->
            error
              (Printf.sprintf
                 "save refused as stale (incoming turn %d < known turn %d) — \
                  the checkpoint changed underneath the purge; re-run against \
                  the current file (backup retained)"
                 incoming_turn_count
                 known_turn_count)
          | Ok (Store.Saved { relation = _; turn_count }) ->
            Printf.printf
              "applied: purged checkpoint saved at turn_count %d\n"
              turn_count))
     )
