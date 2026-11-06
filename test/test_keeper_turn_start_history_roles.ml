(** A Keeper turn that starts from the checkpoint the Anthropic lane saved
    can be sent to the Anthropic lane again.

    The Anthropic collection keeps the turn's context carrier in history as
    a [Historical_system_context] row. Preparing the next turn must keep that
    row as it was saved: a carrier read back with another role is refused by
    the request codec, and the Keeper fails every turn on that lane. *)

open Masc

let fail = Alcotest.fail

let () = Server_startup_state.mark_state_ready () |> Result.get_ok

(* Preparing a turn renders the Keeper prompt, so resolution points at the
   repository's own prompt files. *)
let () =
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ()

let temp_dir () =
  let root = Filename.temp_file "test_turn_start_roles_" "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  root
;;

let rec remove path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let message ?(origin = Llm_provider.Types.Conversation) role content : Agent_core.Types.message =
  { origin; role; content; name = None; tool_call_id = None; metadata = [] }
;;

(* A saved history whose [Historical_system_context] row has the System role:
   the caller, that row, one tool round and the answer. *)
let saved_history =
  let open Agent_core.Types in
  [ message User [ Text "autonomous turn" ]
  ; message ~origin:Llm_provider.Types.Historical_system_context System
      [ Text "[system context] world state" ]
  ; message Assistant
      [ Text "reading the board"; ToolUse { id = "call-1"; name = "inspect"; input = `Assoc [] } ]
  ; message Tool
      [ ToolResult
          { tool_use_id = "call-1"
          ; content = "two posts"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; message Assistant [ Text "nothing new" ]
  ]
;;

let checkpoint ~session_id : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "turn-start-roles"
  ; model = "claude-sonnet-5-5"
  ; system_prompt = None
  ; messages = saved_history
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 1
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
;;

(* The Messages lane declared in models.toml for claude-sonnet-5-5: context
   carriers travel as turn-scoped system messages. *)
let anthropic_lane_config () =
  let open Agent_core.Llm_provider in
  Provider_config.make ~kind:Anthropic ~model_id:"claude-sonnet-5-5"
    ~base_url:"https://api.anthropic.com" ~max_tokens:4096 ~system_prompt:"keeper system"
    ~model_capabilities_override:
      { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
        reasoning_replay_override = Capabilities.Force_turn_scoped_system_context_preserve_always
      }
    ()
;;

let prepared_history () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> remove base_dir) @@ fun () ->
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "turn-start-roles" ]) with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Filename.concat base_dir session_id in
  Fs_compat.mkdir_p session_dir;
  (match
     Keeper_checkpoint_store.save_agent_core_classified
       ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~history_retained:0 ~session_dir
       (checkpoint ~session_id)
   with
   | Ok _ -> ()
   | Error detail -> fail ("seed checkpoint: " ^ detail));
  match
    Keeper_run_context.prepare_run_context ~config:(Workspace.default_config base_dir) ~meta
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults ~base_dir
      ~runtime_id:"unconfigured-test-runtime" ()
  with
  | Error (Keeper_run_context.Checkpoint_unread error) ->
    fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  | Error (Keeper_run_context.Base_prompt_unavailable error) ->
    fail (Keeper_run_context.base_prompt_error_to_string error)
  | Error (Keeper_run_context.Prompt_unrenderable detail)
  | Error (Keeper_run_context.Turn_system_unreadable detail) -> fail detail
  | Ok { resume_agent_core_checkpoint = None; _ } -> fail "the saved checkpoint is resumed"
  | Ok { resume_agent_core_checkpoint = Some resumed; _ } -> resumed.messages
;;

let role_name = function
  | Agent_core.Types.System -> "system"
  | Agent_core.Types.User -> "user"
  | Agent_core.Types.Assistant -> "assistant"
  | Agent_core.Types.Tool -> "tool"
;;

let test_next_turn_keeps_the_saved_carrier_and_reaches_the_anthropic_lane () =
  let prepared = prepared_history () in
  Alcotest.(check (list string)) "the prepared turn keeps every saved role"
    (List.map (fun (m : Agent_core.Types.message) -> role_name m.role) saved_history)
    (List.map (fun (m : Agent_core.Types.message) -> role_name m.role) prepared);
  let next_turn = prepared @ [ message Agent_core.Types.User [ Agent_core.Types.Text "next wake" ] ] in
  let wire =
    match Agent_core.History.to_wire_messages (Agent_core.History.Memory_store.create ()) next_turn with
    | Ok wire -> wire
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error))
  in
  let body =
    match
      Agent_core.Llm_provider.Backend_anthropic.build_request ~config:(anthropic_lane_config ())
        ~messages:wire ()
    with
    | body -> Yojson.Safe.from_string body
    | exception Invalid_argument detail -> fail ("the Anthropic lane refuses the turn: " ^ detail)
  in
  let open Yojson.Safe.Util in
  let carrier = body |> member "messages" |> to_list |> fun messages -> List.nth messages 1 in
  Alcotest.(check string) "the carrier is sent as turn-scoped system context" "system"
    (carrier |> member "role" |> to_string);
  Alcotest.(check string) "it clears at the next user message" "next_user_message"
    (carrier |> member "clear_at" |> to_string)
;;

let () =
  Alcotest.run "keeper_turn_start_history_roles"
    [ ( "anthropic lane"
      , [ Alcotest.test_case "the next turn keeps the saved carrier and reaches the lane" `Quick
            test_next_turn_keeps_the_saved_carrier_and_reaches_the_anthropic_lane
        ] )
    ]
;;
