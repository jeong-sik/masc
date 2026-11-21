module T = Masc_tui_types
module Tui_decode = Masc.Tui_decode
module Checkpoint_pending = Masc_tui_msx_checkpoint_pending

type view_token = unit ref

let capture_machine_view (state : T.state) = state.T.msx_view_authority

let machine_view_is_current (state : T.state) (view : view_token) =
  view == state.T.msx_view_authority

let live_request_is_current (state : T.state) (request : T.machine_live_request) =
  request.T.live_view == state.T.msx_view_authority && request.T.live_port = state.T.port

let retire_machine_view (state : T.state) =
  state.T.msx_view_authority <- ref ()

let checkpoint_root workspace =
  Tui_decode.Canonical_path.to_string workspace.Tui_decode.sid_masc_root

let checkpoint_binding (pending : T.pending_msx_checkpoint) =
  Result.map (fun operation_id ->
    { Checkpoint_pending.operation_id
    ; restore = pending.T.checkpoint_restore
    ; slot = pending.T.checkpoint_slot
    ; base_path = Tui_decode.Canonical_path.to_string pending.T.checkpoint_workspace.Tui_decode.sid_base_path
    ; masc_root = checkpoint_root pending.T.checkpoint_workspace
    })
    (Keeper_operation_id.of_string pending.T.checkpoint_operation_id)

let recover_checkpoints (state : T.state) workspace =
  let root = checkpoint_root workspace in
  let base_path = Tui_decode.Canonical_path.to_string workspace.Tui_decode.sid_base_path in
  (* Other TUI processes can publish an unresolved intent after our first read.
     Read the shared inventory on every write-admission check. *)
  if Result.is_ok (T.workspace_change_origin state) then
    match Checkpoint_pending.load ~masc_root:root with
    | Error detail ->
        Hashtbl.replace state.T.msx_checkpoint_storage_errors root detail;
        state.T.msx_notice <- Some ("Checkpoint intent storage unavailable; machine changes blocked: " ^ detail)
    | Ok bindings ->
        (* [load] keeps only bindings under [root], and the filter keeps only
           those under [base_path], so each one names [workspace]'s paths. *)
        let recovered = List.map (fun (binding : Checkpoint_pending.binding) ->
          { T.checkpoint_operation_id = Keeper_operation_id.to_string binding.Checkpoint_pending.operation_id
          ; checkpoint_restore = binding.Checkpoint_pending.restore
          ; checkpoint_slot = binding.Checkpoint_pending.slot
          ; checkpoint_workspace = workspace
          })
          (List.filter (fun (binding : Checkpoint_pending.binding) -> binding.Checkpoint_pending.base_path = base_path) bindings) in
        state.T.msx_pending_checkpoints <- recovered @ List.filter (fun (pending : T.pending_msx_checkpoint) ->
          Tui_decode.Canonical_path.to_string pending.T.checkpoint_workspace.Tui_decode.sid_base_path <> base_path
          || checkpoint_root pending.T.checkpoint_workspace <> root) state.T.msx_pending_checkpoints;
        Hashtbl.remove state.T.msx_checkpoint_storage_errors root;
        if recovered <> [] then
          state.T.msx_notice <- Some "Unresolved checkpoint recovered; F5 inspects its original receipt before machine control resumes."

let checkpoint_for_workspace (state : T.state) =
  match state.T.server_identity with
  | None -> None
  | Some workspace ->
      recover_checkpoints state workspace;
      List.find_opt (fun (pending : T.pending_msx_checkpoint) ->
        Tui_decode.Canonical_path.equal pending.T.checkpoint_workspace.Tui_decode.sid_base_path
          workspace.Tui_decode.sid_base_path
        && checkpoint_root pending.T.checkpoint_workspace = checkpoint_root workspace)
        state.T.msx_pending_checkpoints

let remember_checkpoint (state : T.state) (pending : T.pending_msx_checkpoint) =
  let root = checkpoint_root pending.T.checkpoint_workspace in
  match checkpoint_binding pending with
  | Error detail -> Error detail
  | Ok binding ->
      (match Checkpoint_pending.remember ~masc_root:root binding with
       | Error detail -> Error detail
       | Ok () -> state.T.msx_pending_checkpoints <- pending :: state.T.msx_pending_checkpoints; Ok ())

let forget_checkpoint (state : T.state) (pending : T.pending_msx_checkpoint) =
  let root = checkpoint_root pending.T.checkpoint_workspace in
  match Result.bind (checkpoint_binding pending) (Checkpoint_pending.forget ~masc_root:root) with
  | Error detail -> Hashtbl.replace state.T.msx_checkpoint_storage_errors root detail
  | Ok () ->
      Hashtbl.remove state.T.msx_checkpoint_storage_errors root;
      state.T.msx_pending_checkpoints <- List.filter (fun (held : T.pending_msx_checkpoint) ->
        held.T.checkpoint_operation_id <> pending.T.checkpoint_operation_id
        || checkpoint_root held.T.checkpoint_workspace <> root) state.T.msx_pending_checkpoints

let machine_changes_allowed (state : T.state) =
  Result.is_ok (T.workspace_change_origin state)
  && Option.is_none (checkpoint_for_workspace state)
  && not (Option.exists (fun workspace -> Hashtbl.mem state.T.msx_checkpoint_storage_errors (checkpoint_root workspace)) state.T.server_identity)

let machine_change_refusal = "MSX control requires a verified server matching this TUI's local workspace."

(* The cached identity only describes the last read. A machine mutation
   revalidates its captured endpoint immediately before dispatch, and its
   completion owns only the view and authority that requested it. A change
   the workspace guard stops never left, so it goes to [withdrawn] with its
   refusal, apart from [deliver]'s refusals and unknown outcomes (RFC §2). *)
let run_machine_change ?(checkpoint_boundary = false) (state : T.state) ~mailbox ~refused ~unknown ~withdrawn ~deliver write =
  let authority = state.T.workspace_authority in
  (* Hold the [unit ref] authority token in a local [ref] cell so
     [checkpoint_boundary] can rebind it after [retire_machine_view] while
     [current ()] still checks physical identity ([==]). *)
  let view = ref state.T.msx_view_authority in
  let port = state.T.port in
  let identity = state.T.server_identity in
  let check = Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox in
  let current () =
    authority = state.T.workspace_authority && !view == state.T.msx_view_authority && port = state.T.port
  in
  (* The identity the check confirmed is the one the request carries, so the
     server compares it again at the moment it applies the change. *)
  let admission =
    try
      if not (machine_changes_allowed state) then Error (T.Request_failed machine_change_refusal)
      else match identity, check () with
      | _, Error refusal -> Error (T.Request_withdrawn refusal)
      | None, Ok () -> Error (T.Request_withdrawn T.Workspace_identity_not_confirmed)
      | Some expected, Ok () when current () && machine_changes_allowed state -> Ok expected
      | Some _, Ok () -> Error (T.Request_failed "MSX control view or workspace authority withdrawn")
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (T.Request_failed (Printexc.to_string exn))
  in
  match admission with
  | Error (T.Request_failed detail) when current () ->
      state.T.machine_interaction <- T.Observe_machine;
      deliver None (Error (refused detail))
  | Error (T.Request_withdrawn refusal) when current () ->
      state.T.machine_interaction <- T.Observe_machine;
      withdrawn refusal
  | Error (T.Request_failed _ | T.Request_withdrawn _) -> ()
  | Ok expected_workspace ->
      let result =
        try
            if checkpoint_boundary then begin
              retire_machine_view state;
              view := state.T.msx_view_authority;
              state.T.msx_live_in_flight <- None
            end;
            (* No yield separates retirement from the checkpoint callback,
               which records its pending identity before sending HTTP. *)
            write ~port ~expected_workspace
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (unknown (Printexc.to_string exn))
      in
      if current () then deliver (Some expected_workspace) result
