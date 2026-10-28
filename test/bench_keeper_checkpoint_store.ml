(** Measures what the Keeper checkpoint store writes and reads against the
    size of the history it already holds (RFC-0476 L0).

    Each case builds a history of tool cycles shaped like the live fleet on
    2026-10-28: a message body near the 1.3 KB median without media, and,
    when asked, an image in some tool results the size of a [masc_dos_screen]
    frame (those averaged 80.8 KB of base64). It then:
    - saves the whole history once;
    - runs tool rounds that each append an assistant tool call and its result
      and save three times, as the pipeline saves once per stage of a round;
    - drops what the store keeps and loads the history (a cold read, as the
      first turn after a restart does);
    - reads the exact snapshot (read and hash, as Librarian and tail recovery
      do).

    Not a test: it prints one row per case. Run by hand from
    _build/default/test, naming each case by its message count or
    [messages:images]:
    ./bench_keeper_checkpoint_store.exe 1000 5000 16000 9000:1500 *)

open Masc
module Store = Keeper_checkpoint_store
module T = Agent_core.Types

(* The live median message without media is 1.3 KB. *)
let body_bytes = 1_200

(* Base64 of this many bytes is about 80 KB, a [masc_dos_screen] frame. *)
let image_raw_bytes = 60_000
let rounds = 5

(* After_assistant_collected, After_tool_results_appended,
   After_context_injection. *)
let saves_per_round = 3
let keeper_name = "bench-checkpoint-keeper"
let session_id = "session"
let default_cases = [ "1000"; "5000"; "16000"; "9000:1500" ]
let get label = function Ok value -> value | Error detail -> failwith (label ^ ": " ^ detail)

let message role content =
  { T.origin = Llm_provider.Types.Conversation; role; content; name = None; tool_call_id = None
  ; metadata = [] }

(* Distinct bytes per image, so no two frames share an encoding. *)
let image_data rng =
  Base64.encode_exn (String.init image_raw_bytes (fun _ -> Char.chr (Random.State.int rng 256)))

let body index = Printf.sprintf "%08d%s" index (String.make (body_bytes - 8) 'b')

let tool_cycle rng ~index ~with_image =
  let id = Printf.sprintf "t%d" index in
  let content_blocks =
    if with_image
    then
      Some
        [ T.Text (body index)
        ; T.Image
            { media_type = "image/png"; data = image_data rng; source_type = Llm_provider.Types.Base64 }
        ]
    else None
  in
  [ message T.Assistant [ T.Text (body index); T.ToolUse { id; name = "bench_tool"; input = `Assoc [] } ]
  ; message
      T.Tool
      [ T.ToolResult
          { tool_use_id = id; content = body index; outcome = T.Tool_succeeded; json = None
          ; content_blocks }
      ]
  ]

(* Spreads [images] over [cycles] so exactly [min images cycles] carry one. *)
let carries_image ~images ~cycles index =
  images > 0 && ((index + 1) * images / cycles) > (index * images / cycles)

let history rng ~messages ~images =
  let cycles = max 1 (messages / 2) in
  message T.User [ T.Text (body 0) ]
  :: List.concat
       (List.init cycles (fun index ->
          tool_cycle rng ~index ~with_image:(carries_image ~images ~cycles index)))

let checkpoint ~turn_count messages =
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version; session_id
    ; agent_name = "agent_core-bench-runtime"; model = "bench-model"; system_prompt = None; messages
    ; usage = Agent_core.Types.empty_usage; turn_count; created_at = 1000.0; tools = []
    ; tool_choice = None; disable_parallel_tool_use = false; temperature = None; top_p = None
    ; top_k = None; min_p = None; reasoning_effort = None; enable_thinking = None
    ; preserve_thinking = None; response_format = Agent_core.Types.Off; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync (); pending_input = None; mcp_sessions = []
    ; working_context = None }

let timed f =
  let started = Unix.gettimeofday () in
  let value = f () in
  value, (Unix.gettimeofday () -. started) *. 1000.0

let file_bytes path = (Unix.stat path).Unix.st_size
let mb bytes = float_of_int bytes /. 1_048_576.0

let median values =
  let sorted = List.sort Float.compare values in
  List.nth sorted (List.length sorted / 2)

let with_session_root f =
  let root = Filename.temp_file "bench-keeper-checkpoint" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let parse_case spec =
  match String.split_on_char ':' spec with
  | [ messages ] -> int_of_string messages, 0
  | [ messages; images ] -> int_of_string messages, int_of_string images
  | _ -> invalid_arg ("case is MESSAGES or MESSAGES:IMAGES: " ^ spec)

let run_case ~history_retained spec =
  let messages, images = parse_case spec in
  with_session_root
  @@ fun root ->
  let session_dir = Filename.concat root session_id in
  Unix.mkdir session_dir 0o700;
  let canonical = Store.agent_core_checkpoint_path ~session_dir ~session_id in
  let rng = Random.State.make [| messages; images |] in
  let save turn_count messages =
    Store.save_agent_core_for_keeper ~keeper_name ~session_dir ~history_retained
      (checkpoint ~turn_count messages)
    |> Result.map (fun (_ : Store.save_agent_core_outcome) -> ())
    |> get "save"
  in
  let initial = history rng ~messages ~images in
  let (), first_save_ms = timed (fun () -> save 1 initial) in
  let file_after_first = file_bytes canonical in
  let round_ms, round_written =
    List.init rounds Fun.id
    |> List.fold_left
         (fun (held, times, written) round ->
            let held = held @ tool_cycle rng ~index:(messages + round) ~with_image:false in
            let turn_count = 2 + round in
            let (), ms =
              timed (fun () ->
                for _ = 1 to saves_per_round do
                  save turn_count held
                done)
            in
            held, ms :: times, written + (saves_per_round * file_bytes canonical))
         (initial, [], 0)
    |> fun (_, times, written) -> times, written / rounds
  in
  Store.forget_written_lineages ~session_root:root ~keeper_name;
  let loaded, cold_load_ms =
    timed (fun () ->
      Store.load_agent_core ~session_dir ~session_id
      |> Result.map_error (fun (_ : Store.checkpoint_load_error) -> "cold load failed")
      |> get "load")
  in
  let (_ : Store.exact_checkpoint_snapshot), exact_read_ms =
    timed (fun () ->
      Store.load_agent_core_exact_snapshot ~session_dir ~session_id
      |> Result.map_error Store.checkpoint_ref_load_error_to_string
      |> get "exact snapshot")
  in
  Printf.printf "%-10s %8d %7d %9.1f %10.1f %10.1f %11.1f %10.1f %10.1f\n%!" spec
    (List.length loaded.Agent_core.Checkpoint.messages) images (mb file_after_first) first_save_ms
    (median round_ms) (mb round_written) cold_load_ms exact_read_ms

let () =
  let cases =
    match Array.to_list Sys.argv with
    | _ :: (_ :: _ as given) -> given
    | [] | [ _ ] -> default_cases
  in
  Server_startup_state.mark_state_ready () |> Result.get_ok;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let history_retained = Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained in
  Printf.printf "%-10s %8s %7s %9s %10s %10s %11s %10s %10s\n" "case" "messages" "images" "file_MB"
    "save_ms" "round_ms" "round_MB" "cold_ms" "exact_ms";
  List.iter (run_case ~history_retained) cases
