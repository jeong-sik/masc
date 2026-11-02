(* Exercise the installed command in a separate process against a head and
   objects written by the real Keeper checkpoint store. *)
open Alcotest
open Masc

let keeper = "checkpoint-inspection-fixture"
let trace = "checkpoint-inspection-trace"

let require label = function
  | Ok value -> value
  | Error detail -> fail (label ^ ": " ^ detail)

let message role content =
  Agent_core.Types.{ origin = Llm_provider.Types.Conversation; role; content;
                     name = None; tool_call_id = None; metadata = [] }

let checkpoint () =
  let open Agent_core.Types in
  let messages =
    [ message User [Text "Run the command"]
    ; message Assistant [ToolUse {id="call"; name="Execute"; input=`Assoc []}]
    ; message Tool [ToolResult {tool_use_id="call";
                                content="{\"marker\":\"marker\",\"cwd\":\"/sandbox\",\"hostname\":\"guest\",\"uid\":1000}";
                                outcome=Tool_succeeded; json=None; content_blocks=None}]
    ; message Assistant [Text "finished"] ]
  in
  Agent_core.Checkpoint.{ provider_binding = None; version = checkpoint_version;
    session_id = trace; agent_name = keeper; model = "fixture"; system_prompt = None;
    messages; usage = empty_usage; turn_count = 1; created_at = 1000.0; tools = [];
    tool_choice = None; disable_parallel_tool_use = false; temperature = None;
    top_p = None; top_k = None; min_p = None; reasoning_effort = None;
    enable_thinking = None; preserve_thinking = None; response_format = Off;
    cache_system_prompt = false; context = Agent_core.Context.create_sync ();
    pending_input = None; mcp_sessions = []; working_context = None }

let rec remove path =
  match Unix.lstat path with
  | {Unix.st_kind = Unix.S_DIR; _} ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path

let run_program root executable args =
  let stdout_path = Filename.concat root "inspect.stdout" in
  let stderr_path = Filename.concat root "inspect.stderr" in
  let flags = [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] in
  let stdout_fd = Unix.openfile stdout_path flags 0o600 in
  let stderr_fd = Unix.openfile stderr_path flags 0o600 in
  let env = [|"HOME=" ^ root; "MASC_BASE_PATH=" ^ root;
               "PATH=" ^ Option.value ~default:"/usr/bin:/bin" (Sys.getenv_opt "PATH")|] in
  let pid = Unix.create_process_env executable (Array.of_list (executable :: args))
      env Unix.stdin stdout_fd stderr_fd in
  Unix.close stdout_fd;
  Unix.close stderr_fd;
  let _, status = Unix.waitpid [] pid in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  status, read stdout_path, read stderr_path

let run_cli root name =
  let executable = Sys.getenv "MASC_TEST_MASC_EXE" |> Unix.realpath in
  run_program root executable ["inspect-checkpoint"; "--base-path"; root; "--keeper"; name]

let run_smoke_consumer root mode =
  let executable = Sys.getenv "MASC_TEST_MASC_EXE" |> Unix.realpath in
  let script = Sys.getenv "MASC_TEST_SMOKE_PY" |> Unix.realpath in
  match run_program root "python3" [script; mode; executable; root] with
  | Unix.WEXITED 0, _, _ -> ()
  | _, stdout, stderr -> fail ("smoke consumer rejected the real checkpoint: " ^ stdout ^ stderr)

let require_json root name =
  match run_cli root name with
  | Unix.WEXITED 0, stdout, _ -> Yojson.Safe.from_string stdout
  | _, stdout, stderr -> fail ("inspection failed: " ^ stdout ^ stderr)

let expect_refusal root name =
  match run_cli root name with
  | Unix.WEXITED 0, stdout, stderr -> fail ("inspection accepted invalid input: " ^ stdout ^ stderr)
  | Unix.WEXITED _, _, _ -> ()
  | (Unix.WSIGNALED _ | Unix.WSTOPPED _), stdout, stderr ->
    fail ("inspection terminated abnormally: " ^ stdout ^ stderr)

let test_canonical_objects () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    Fs_compat.set_fs env#fs;
    ignore (Server_startup_state.mark_state_ready ());
    let root = Filename.temp_file "checkpoint-inspection" "" in
    Unix.unlink root;
    Unix.mkdir root 0o700;
    let root = Unix.realpath root in
    Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let workspace = Workspace.default_config root in
      ignore (Workspace.init workspace ~agent_name:(Some "checkpoint-inspection-test"));
      let meta = Masc_test_deps.meta_of_json_fixture
          (`Assoc ["name", `String keeper; "trace_id", `String trace;
                   "activation_mode", `String "manual"]) |> require "metadata" in
      Keeper_meta_store.replace_snapshot workspace meta |> require "write metadata";
      let session_dir = Filename.concat (Keeper_fs.session_store_path_for_base_path root) trace in
      let open Yojson.Safe.Util in
      let missing = require_json root keeper in
      check string "missing canonical" "not_found" (missing |> member "status" |> to_string);
      let value = checkpoint () in
      let save boundary value =
        ignore (Keeper_checkpoint_store.save_agent_core_classified
          ~boundary ~history_retained:0 ~session_dir value |> require "save canonical") in
      save Agent_core.Checkpoint_objects.Turn_continues value;
      let open_head = require_json root keeper in
      check int "open checkpoint has no closed messages" 0
        (open_head |> member "history_boundary" |> member "closed_messages" |> to_int);
      check int "open checkpoint holds all messages" 4
        (open_head |> member "history_boundary" |> member "open_messages" |> to_int);
      run_smoke_consumer root "--expect-open-fixture";
      save Agent_core.Checkpoint_objects.Turn_closes value;
      let head_path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace in
      let actual = require_json root keeper in
      check string "available canonical" "available" (actual |> member "status" |> to_string);
      check string "keeper" keeper (actual |> member "keeper" |> to_string);
      check string "trace" trace (actual |> member "trace_id" |> to_string);
      check string "canonical path" head_path (actual |> member "canonical_path" |> to_string);
      let projection = actual |> member "checkpoint" in
      check string "projection session" trace (projection |> member "session_id" |> to_string);
      check int "projection messages" 4 (projection |> member "messages" |> to_list |> List.length);
      let reference = actual |> member "reference" in
      check int "reference turn" 1 (reference |> member "turn_count" |> to_int);
      check int "content digest length" 64 (reference |> member "content_sha256" |> to_string |> String.length);
      check string "closing a turn preserves the content digest"
        (open_head |> member "reference" |> member "content_sha256" |> to_string)
        (reference |> member "content_sha256" |> to_string);
      check int "closed checkpoint holds all messages" 4
        (actual |> member "history_boundary" |> member "closed_messages" |> to_int);
      check int "closed checkpoint has no open messages" 0
        (actual |> member "history_boundary" |> member "open_messages" |> to_int);
      run_smoke_consumer root "--real-fixture";
      let later = {value with Agent_core.Checkpoint.turn_count = 2;
        messages = value.messages @ [message Agent_core.Types.User [Agent_core.Types.Text "later"]]} in
      save Agent_core.Checkpoint_objects.Turn_continues later;
      let with_later_open = require_json root keeper in
      check int "old turn remains closed" 4
        (with_later_open |> member "history_boundary" |> member "closed_messages" |> to_int);
      check int "new turn remains open" 1
        (with_later_open |> member "history_boundary" |> member "open_messages" |> to_int);
      run_smoke_consumer root "--real-fixture";
      let original_head = In_channel.with_open_bin head_path In_channel.input_all in
      let head = Yojson.Safe.from_string original_head in
      let previous_version = match head with
        | `Assoc fields ->
          `Assoc (List.map (fun (key, value) ->
            match key, value with
            | "checkpoint", `Assoc checkpoint ->
              key, `Assoc (List.map (fun (field, item) ->
                if String.equal field "version"
                then field, `Int (Agent_core.Checkpoint.checkpoint_version - 1)
                else field, item) checkpoint)
            | _, _ -> key, value) fields)
        | _ -> fail "writer produced a non-object head" in
      Yojson.Safe.to_file head_path previous_version;
      expect_refusal root keeper;
      Out_channel.with_open_bin head_path (fun ch -> output_string ch original_head);
      let turns = head |> member "history" |> member "turns" |> to_list in
      let digest = match turns with
        | turn :: _ -> turn |> member "bundle" |> to_string
        | [] -> fail "writer did not create a turn bundle" in
      let object_path = Filename.concat
          (Filename.concat (Filename.concat session_dir "objects") (String.sub digest 0 2)) digest in
      let original_object = In_channel.with_open_bin object_path In_channel.input_all in
      Out_channel.with_open_bin object_path (fun ch -> output_string ch "corrupt");
      expect_refusal root keeper;
      Out_channel.with_open_bin object_path (fun ch -> output_string ch original_object);
      Unix.rename head_path (Filename.concat session_dir "agent-core-snapshot-0000000001000.json");
      let missing_again = require_json root keeper in
      check string "missing head is not an archive" "not_found"
        (missing_again |> member "status" |> to_string);
      expect_refusal root "../another-keeper")))

let () = run "checkpoint inspection CLI"
    ["canonical", [test_case "production objects and refusals" `Quick test_canonical_objects]]
