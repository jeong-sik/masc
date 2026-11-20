module T = Masc_tui_types
module Keeper_chat = Masc_tui_keeper_chat_projection

let recovered_paste_send_locked_for (state : T.state) keeper_name =
  match keeper_name with
  | Some target ->
      List.exists (String.equal target) state.msg_recovered_paste_keepers
  | None -> false

let recovered_paste_send_locked (state : T.state) =
  recovered_paste_send_locked_for state state.msg_target_keeper_name

let discard_recovered_paste_lock (state : T.state) =
  match state.msg_target_keeper_name with
  | Some target ->
      state.msg_recovered_paste_keepers <-
        List.filter
          (fun name -> not (String.equal name target))
          state.msg_recovered_paste_keepers
  | None -> ()

let protect_recovered_paste_for_current_keeper (state : T.state) =
  match state.msg_target_keeper_name with
  | Some target when not (recovered_paste_send_locked state) ->
      state.msg_recovered_paste_keepers <-
        target :: state.msg_recovered_paste_keepers
  | Some _ | None -> ()

(* Put the pasted text back into the draft where its placeholder stands.

   The spill is dropped whether or not its line was still there. An operator
   who deleted the placeholder meant to drop the paste, and a spill that
   outlived the draft would attach itself to the next message. *)
let inline_spilled_paste spill text = T.expand_message_draft_spill spill text

let materialise_spilled_paste (state : T.state) snapshot =
  let text =
    inline_spilled_paste
      (T.message_spill_in_snapshot state snapshot)
      (Masc_tui_message_input.snapshot_text snapshot)
  in
  state.msg_spill <- None;
  text

(* Where this process stages a spilled paste for the keeper.

   [Keeper_sandbox_config] is the same answer the server gives: it reads the
   keeper's own TOML for the sandbox profile and returns the backend-scoped
   root -- [.masc/playground/docker/<name>/] for a Docker keeper and
   [.masc/playground/<name>/] for the endpoint-owned profiles (microvm,
   remote_ssh). Working the path out here instead would be this process
   copying a layout the server owns, and the two roots differ by a directory
   that is easy to get right once and wrong afterwards.

   "Staging" is the honest word. For Docker the root is bind-mounted into
   the container, so the staged file is already where the keeper reads it.
   For an endpoint-owned tree the root is only the host bookkeeping bundle
   and the keeper cannot see it; [Keeper_paste_delivery] carries the file to
   the endpoint's workspace root at the next turn setup, the first moment a
   turn-owned endpoint exists. Writing here at paste time is still right:
   the paste is durable from the moment the operator sends it, and no
   endpoint has to be up for this process to receive it.

   [None] when the root cannot be named or does not exist. A keeper that has
   never run has no playground, and creating one from outside would be this
   process deciding something about the keeper's own space. *)
let keeper_staging_dir ~base_path ~keeper_name =
  match
    Keeper_sandbox_config.sandbox_profile_of_agent ~base_path
      ~agent_name:keeper_name
  with
  (* [sandbox_profile_of_agent] raises on a keeper TOML it cannot read, and
     [Sys.is_directory] raises on a path that went away between the two
     calls. Neither is a reason to lose the paste -- the caller falls back to
     sending the text. *)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> None
  | profile -> (
      let dir =
        Filename.concat base_path
          (Keeper_sandbox_config.host_root_rel_of_profile profile keeper_name)
      in
      if Env_config_core.existing_dir dir then Some (dir, profile) else None)

(* Publish a completed temporary file without replacing an earlier paste.
   Keeper paste delivery enumerates only [Keeper_paste_naming] names, so it
   cannot pick up the temporary file while it is being written. *)
let write_file path contents =
  let drop_tmp tmp_path = try Sys.remove tmp_path with Sys_error _ -> () in
  match
    Filename.temp_file ~temp_dir:(Filename.dirname path) "spill-write-" ".tmp"
  with
  | exception Sys_error detail -> Error detail
  | tmp_path ->
      Fun.protect
        ~finally:(fun () -> drop_tmp tmp_path)
        (fun () ->
          let written =
            match open_out_bin tmp_path with
            | exception Sys_error detail -> Error detail
            | channel -> (
                match
                  Fun.protect
                    ~finally:(fun () -> close_out_noerr channel)
                    (fun () ->
                      output_string channel contents;
                      close_out channel)
                with
                | () -> Ok ()
                | exception Sys_error detail -> Error detail)
          in
          match written with
          | Error _ as error -> error
          | Ok () -> (
              match Unix.link tmp_path path with
              | () -> Ok ()
              | exception Unix.Unix_error (error, _, _) ->
                  Error (Unix.error_message error)))

(* Stage a spilled paste as a file the keeper will be able to read, and put
   a line naming that file where the placeholder stands.

   Measured before it was built: a keeper reads paths relative to its own
   sandbox root and refuses anything outside it, so [/tmp] comes back as
   [path_outside_sandbox] and a workspace-relative path is simply not found.
   The file goes into the root the server names for this keeper and the
   message names it bare.

   For Docker that root is the bind-mounted workspace itself, so the file is
   already where the keeper reads it. For the endpoint-owned profiles it is
   the host bookkeeping bundle -- staging, not the destination -- and
   [Keeper_paste_delivery] writes it through the remote lane at the next
   turn setup. The keeper-facing line ("It is in your working directory")
   becomes true before that turn's first Read.

   Every failure falls back to sending the text itself. A paste that reached
   the keeper as a large message is worse than one it can read off disk; a
   paste that reached it as neither is the thing this must not do. *)
let place_spilled_paste (state : T.state) ~keeper_name ~staging_dir
    (saved : T.saved_message_spill) =
  let spill = saved.T.sms_paste in
  let inline () =
    Masc_tui_message_input.replace_owned saved.T.sms_view
      ~replacement:spill.Masc_tui_paste_spill.text
  in
  let pointed =
    Masc_tui_message_input.replace_owned saved.T.sms_view
      ~replacement:(Masc_tui_paste_spill.message_line spill)
  in
  match staging_dir with
  | None ->
      Masc_tui_loader.report_action state "system"
        (Printf.sprintf
           "%s has no workspace on disk; sending the pasted text in the \
            message instead"
           (Keeper_chat.terminal_safe_text keeper_name));
      inline ()
  | Some (dir, profile) -> (
      let path =
        Filename.concat dir spill.Masc_tui_paste_spill.file_name
      in
      match write_file path spill.Masc_tui_paste_spill.text with
      | Error detail ->
          Masc_tui_loader.report_action state "error"
            (Printf.sprintf
               "Could not write the pasted text for %s (%s); sending it in \
                the message instead"
               (Keeper_chat.terminal_safe_text keeper_name)
               detail);
          inline ()
      | Ok () ->
          (match profile with
           | Keeper_sandbox_config.Docker ->
               (* The staged directory is the bind-mounted workspace
                  itself: written is delivered. *)
               Masc_tui_loader.report_action state "system"
                 (Printf.sprintf "Wrote %s (%d bytes) into %s's workspace"
                    spill.Masc_tui_paste_spill.file_name
                    spill.Masc_tui_paste_spill.bytes
                    (Keeper_chat.terminal_safe_text keeper_name))
           | Keeper_sandbox_config.Micro_vm
           | Keeper_sandbox_config.Remote_ssh ->
               Masc_tui_loader.report_action state "system"
                 (Printf.sprintf
                    "Staged %s (%d bytes) for %s; it lands in the workspace \
                     when the next turn starts"
                    spill.Masc_tui_paste_spill.file_name
                    spill.Masc_tui_paste_spill.bytes
                    (Keeper_chat.terminal_safe_text keeper_name)));
          pointed)

type prepared_spill =
  { ps_spill : T.message_spill
  ; ps_source : T.saved_message_spill
  ; ps_directory : (string * Keeper_sandbox_config.sandbox_profile) option
  }

(* Resolving a Keeper's sandbox may yield. Keep the composer and queue intact
   until the original owner and edit are still current after that read. *)
let prepare_spilled_paste (state : T.state) ~base_path ~keeper_name
    ~still_allowed saved =
  match (saved, state.msg_spill) with
  | None, _ -> Ok None
  | Some _, None ->
      Error "Input changed while preparing the paste; current draft retained"
  | Some saved, Some spill ->
      let authority = state.workspace_authority in
      let workspace = T.chat_input_workspace state in
      let target = state.msg_target_keeper_name in
      let revision = Masc_tui_message_input.revision state.msg_input in
      let edit = T.current_recall_edit state in
      let control = T.keeper_chat_control_generation state keeper_name in
      if
        not
          (Masc_tui_message_input.owned_is_current state.msg_input
             saved.T.sms_view)
      then Error "Input changed while preparing the paste; current draft retained"
      else
        let directory = keeper_staging_dir ~base_path ~keeper_name in
        if
          state.workspace_authority <> authority
          || T.chat_input_workspace state <> workspace
          || state.msg_target_keeper_name <> target
          || not (Masc_tui_message_input.has_revision state.msg_input revision)
          || not
               (Option.exists
                  (fun current -> current == spill)
                  state.msg_spill)
          || T.current_recall_edit state <> edit
          || T.keeper_chat_control_generation state keeper_name <> control
          || not (still_allowed ())
        then
          Error
            "Input changed while preparing the paste; current draft retained"
        else Ok (Some { ps_spill = spill; ps_source = saved; ps_directory = directory })
