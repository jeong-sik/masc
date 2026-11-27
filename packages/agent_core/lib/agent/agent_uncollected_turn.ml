module Scope = Execution_agent_scope
module Writer = Execution_lane_writer
module Journal = Execution_journal

type retirement =
  | Not_uncollected
  | Retired of Execution_event.terminal * Scope.recovery_evidence

type error =
  | Writer_failed of Writer.scope_failure
  | Scope_failed of Scope.error
  | Raised of exn

let error_to_string = function
  | Writer_failed failure -> "execution writer: " ^ Writer.scope_failure_to_string failure
  | Scope_failed error -> "execution scope: " ^ Scope.error_to_string error
  | Raised exn -> "execution writer raised: " ^ Printexc.to_string exn
;;

let ( let* ) = Result.bind

(* Kept in the journal's terminal for whoever reads the tree; nothing parses it. *)
let cancelled_reason =
  "the host closed a turn its exited writer cut before the provider response was collected"
;;

(* A topology the resume functions refuse (a finished root, several open turns,
   a failed frontier, several provider attempts) is not the shape closed here.
   It stays as it is, and [Agent.run] meets the same refusal it meets today. *)
let within_shape = function
  | Ok value -> Ok (Some value)
  | Error (Scope.Resume_topology_mismatch _) -> Ok None
  | Error
      (( Scope.Admission_failed _
       | Scope.Mutation_failed _
       | Scope.Invalid_provider_attempt _
       | Scope.Scope_unavailable _
       | Scope.Run_not_found
       | Scope.Agent_identity_mismatch _
       | Scope.Invocation_locator_mismatch
       | Scope.Invalid_tool_result
       | Scope.Bus_observation_failed _
       | Scope.Settlement_failed _ ) as error) -> Error error
;;

let closed_terminal writer locator =
  match Writer.find_run writer (Scope.scope_locator_run_id locator) with
  | Error error -> Error (Scope.Scope_unavailable error)
  | Ok None -> Error Scope.Run_not_found
  | Ok (Some { Journal.status = Journal.Finished terminal; _ }) -> Ok terminal.value
  | Ok (Some { Journal.status = Journal.Running; _ }) ->
    Error (Scope.Resume_topology_mismatch "aborted execution run is still running")
;;

let close_attempt writer locator scope attempt =
  let* invocations = Scope.provider_invocations attempt in
  match invocations with
  | _ :: _ -> Ok Not_uncollected
  | [] ->
    let* () =
      Scope.abort scope (Scope.Cancelled { reason = Some cancelled_reason; data = None })
    in
    let* terminal = closed_terminal writer locator in
    let* evidence = Scope.terminal_recovery_evidence scope in
    Ok (Retired (terminal, evidence))
;;

let judge writer locator ~agent_name ~checkpoint_turn_count =
  let* scope = within_shape (Scope.resume_running ~writer ~agent_name locator) in
  match scope with
  | None -> Ok Not_uncollected
  | Some scope ->
    let* turn = within_shape (Scope.resume_current_turn scope) in
    (match turn with
     | None | Some (Scope.Resume_turn_absent | Scope.Resume_turn_settled _) ->
       Ok Not_uncollected
     | Some (Scope.Resume_turn_open turn) ->
       if Scope.turn_ordinal turn <> checkpoint_turn_count
       then Ok Not_uncollected
       else
         let* attempt = within_shape (Scope.resume_provider_attempt turn) in
         (match attempt with
          | None | Some (Scope.Resume_provider_absent | Scope.Resume_provider_settled _) ->
            Ok Not_uncollected
          | Some (Scope.Resume_provider_open attempt) ->
            close_attempt writer locator scope attempt))
;;

let retire ~codec ~dir locator ~agent_name ~checkpoint_turn_count =
  match
    Eio.Cancel.protect (fun () ->
      Writer.resume ~codec ~dir (fun ~sw:_ writer ->
        match Writer.await_ready writer with
        | Error failure -> Error (Writer_failed failure)
        | Ok () ->
          judge writer locator ~agent_name ~checkpoint_turn_count
          |> Result.map_error (fun error -> Scope_failed error)))
  with
  | Ok judged -> judged
  | Error failure -> Error (Writer_failed failure)
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception Writer.Callback_failed_after_scope_failure (_, failure) ->
    Error (Writer_failed failure)
  | exception exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Error (Raised exn)
;;
