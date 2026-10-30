(** Measures what the Keeper checkpoint store writes and reads against the
    size of the history it already holds (RFC-0476 L0).

    Each case builds a history of tool cycles shaped like the live fleet on
    2026-10-28: a message body near the 1.3 KB median without media, and,
    when asked, an image in some tool results the size of a [masc_dos_screen]
    frame (those averaged 80.8 KB of base64). It then:
    - saves the whole history once, as closed turns;
    - runs tool rounds shaped like the pipeline's, inside an open turn: save
      after the assistant tool call, save after its result, save once more for
      the context injection stage. Each save carries its own [created_at], so
      the store keeps and prunes snapshot files as it does live;
    - reads the exact snapshot while the store still holds what it wrote
      (Librarian's case during a Keeper's run), and again after dropping it;
    - drops what the store keeps and loads the history through
      [load_agent_core_for_save], the first turn after a restart.

    [write_B] counts the average successful logical payload bytes a round
    writes: message objects, the head and history fallbacks, not metadata,
    fsync or device traffic. [file_MiB] is the canonical file, which is the
    head (RFC-0476 §3.2).
    An uncertain archive write stops the case instead of reporting a number.
    [disk_MiB] recursively counts retained regular files once per device/inode.
    New checkpoint object writers must join the same observation boundary.

    Not a test: it prints one row per case. Run by hand from
    _build/default/test, naming each case by its message count or
    [messages:images]:
    ./bench_keeper_checkpoint_store.exe 1000 5000 16000 9000:1500 *)

open Masc
module Store = Keeper_checkpoint_store
module T = Agent_core.Types

(* The live median message without media is 1.3 KB. *)
let body_bytes = 1_200

(* A [masc_dos_screen] frame. History holds it by reference, so the
   checkpoint carries its digest and length, not its bytes. *)
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

(* Distinct bytes per image, so no two frames share a reference. *)
let image_source rng =
  T.Stored
    (Agent_core.History.stored_of_raw
       (String.init image_raw_bytes (fun _ -> Char.chr (Random.State.int rng 256))))

let body index = Printf.sprintf "%08d%s" index (String.make (body_bytes - 8) 'b')

let tool_cycle rng ~index ~with_image =
  let id = Printf.sprintf "t%d" index in
  let content_blocks =
    if with_image
    then
      Some
        [ T.Text (body index)
        ; T.Image
            { media_type = "image/png"; source = image_source rng }
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

let checkpoint ~turn_count ~created_at messages =
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version; session_id
    ; agent_name = "agent_core-bench-runtime"; model = "bench-model"; system_prompt = None; messages
    ; usage = Agent_core.Types.empty_usage; turn_count; created_at; tools = []
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
let add_bytes left right =
  if right > max_int - left then failwith "round payload byte count overflow";
  left + right

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
  let saves = ref 0 in
  (* One second apart, so every save names its own snapshot file. *)
  let save ~boundary turn_count messages =
    incr saves;
    let _, written = Store.For_testing.save_agent_core_for_keeper_measured ~boundary
      ~keeper_name ~session_dir ~history_retained
      (checkpoint ~turn_count ~created_at:(1000.0 +. float_of_int !saves) messages)
    |> get "save" in
    let written = match written with
      | Some bytes -> bytes
      | None -> failwith "save payload byte count is unknown" in
    file_bytes canonical, written
  in
  let initial = history rng ~messages ~images in
  let (file_after_first, _), first_save_ms =
    timed (fun () -> save ~boundary:Agent_core.Checkpoint_objects.Turn_closes 1 initial)
  in
  let save = save ~boundary:Agent_core.Checkpoint_objects.Turn_continues in
  let round_ms, round_written =
    List.init rounds Fun.id
    |> List.fold_left
         (fun (held, times, written) round ->
            let assistant, result =
              match tool_cycle rng ~index:(messages + round) ~with_image:(images > 0) with
              | [ assistant; result ] -> assistant, result
              | _ -> invalid_arg "a tool cycle is one call and one result"
            in
            let turn_count = 2 + round in
            let held = held @ [ assistant ] in
            let (held, round_bytes), ms =
              timed (fun () ->
                let _, after_assistant = save turn_count held in
                let held = held @ [ result ] in
                let _, after_results = save turn_count held in
                let _, after_injection = save turn_count held in
                held, add_bytes (add_bytes after_assistant after_results) after_injection)
            in
            held, ms :: times, add_bytes written round_bytes)
         (initial, [], 0)
    |> fun (_, times, written) -> times, written
  in
  let disk = Store.For_testing.retained_payload_bytes ~directory:session_dir in
  let exact () =
    Store.load_agent_core_exact_snapshot ~session_dir ~session_id
    |> Result.map_error Store.checkpoint_ref_load_error_to_string
    |> get "exact snapshot"
  in
  let (_ : Store.exact_checkpoint_snapshot), exact_held_ms = timed exact in
  Store.forget_written_lineages ~session_root:root ~keeper_name;
  let (_ : Store.exact_checkpoint_snapshot), exact_cold_ms = timed exact in
  Store.forget_written_lineages ~session_root:root ~keeper_name;
  let (_ : Agent_core.Checkpoint.t), cold_load_ms =
    timed (fun () ->
      Store.load_agent_core_for_save ~keeper_name ~session_dir ~session_id
      |> Result.map_error (fun (_ : Store.checkpoint_load_error) -> "cold load failed")
      |> get "load")
  in
  Printf.printf "%-10s %8d %7d %8.1f %9.1f %9.1f %14.1f %8.1f %9.1f %9.1f %8.1f\n%!" spec
    (List.length initial) images (mb file_after_first) first_save_ms (median round_ms)
    (float_of_int round_written /. float_of_int rounds) (mb disk) exact_held_ms exact_cold_ms cold_load_ms

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
  Printf.printf "%-10s %8s %7s %8s %9s %9s %14s %8s %9s %9s %8s\n" "case" "messages" "images"
    "file_MiB" "save_ms" "round_ms" "write_B" "disk_MiB" "exact_ms" "exact_cold" "cold_ms";
  List.iter (run_case ~history_retained) cases
