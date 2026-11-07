(* See candle_candidates.mli. *)

open Result.Syntax

type outcome =
  | Wrote_candidates of { goal_id : string }
  | Wrote_unattributed of { goal_id : string }
  | Already_prepared of { goal_id : string }
  | Superseded of { goal_id : string }
  | Held_window of { goal_id : string; issues : Candle_payout.window_issue list; recorded : bool }
  | Waiting_task of { goal_id : string; issues : Candle_payout.window_issue list }
  | Retry_later of { goal_id : string; detail : string }

type sources =
  { task_lookups :
      goal_id:string -> string list -> ((string * Candle_event.task_lookup) list, string) result
  ; is_keeper : unit -> (string -> bool, string) result
  }

let real_sources config =
  { task_lookups = (fun ~goal_id task_ids -> Candle_tasks.observations config ~goal_id task_ids)
  ; is_keeper = (fun () -> Candle_tasks.is_keeper config)
  }
;;

type written =
  | Written
  | Not_written

(* Appends [rows] when the payout is still the open one for [waiting.request_id]
   and [still_needed] holds on the ledger as it is now. The Tasks were read
   outside the ledger's lock, so the ledger may have moved on since. *)
let append_when_still_open ~base_path (waiting : Candle_payout.waiting) ~still_needed rows =
  let* attempt = Result.map_error
    (Candle_ledger.update_error_to_string Fun.id)
    (Candle_ledger.update_once ~base_path (fun view ->
       let events = Candle_ledger.events view in
       match Candle_payout.state ~goal_id:waiting.goal_id events with
       | Candle_payout.Waiting open_payout
         when open_payout = waiting && still_needed events ->
         Ok (rows, Written)
       | Candle_payout.Waiting _ | Candle_payout.No_obligation | Candle_payout.Failed _ | Candle_payout.Settled ->
         Ok ([], Not_written))) in
  Ok (match attempt with Candle_ledger.Updated result -> result | Changed -> Not_written)
;;

let candidates_row ~fenced ~at (waiting : Candle_payout.waiting) tasks (decided : Candle_payout.candidates) =
  { Candle_event.at
  ; body =
      (let candidates : Candle_event.candidate_observation =
        { goal_id = waiting.goal_id
        ; request_id = waiting.request_id
        ; verification_run_id = waiting.verification_run_id
        ; tasks
        ; candidate_task_ids = decided.candidate_task_ids
        ; candidate_keepers = decided.candidate_keepers
        ; candidate_task_keepers = decided.candidate_task_keepers
        } in
       if fenced then Candle_event.Candidates_fenced candidates else Candle_event.Candidates candidates)
  }
;;

let unattributed_row ~at (waiting : Candle_payout.waiting) reason =
  { Candle_event.at
  ; body =
      Candle_event.Unattributed
        { goal_id = waiting.goal_id
        ; request_id = waiting.request_id
        ; verification_run_id = waiting.verification_run_id
        ; reason
        }
  }
;;

let no_candidate_keepers (decided : Candle_payout.candidates) =
  match decided.candidate_keepers with
  | [] -> true
  | _ :: _ -> false
;;

(* A crash between the two rows leaves [Candidates] without its [Unattributed].
   The next pass finds the payout still waiting and writes the missing row. *)
let close_without_keepers ~now ~base_path waiting =
  let* at = Candle_stamp.at ~now in
  let* written =
    append_when_still_open
      ~base_path
      waiting
      ~still_needed:(fun _ -> true)
      [ unattributed_row ~at waiting Candle_event.No_candidates ]
  in
  Ok
    (match written with
     | Written -> Wrote_unattributed { goal_id = waiting.goal_id }
     | Not_written -> Superseded { goal_id = waiting.goal_id })
;;

(* A Goal that linked no Task names nobody, so neither the Tasks nor the Keepers
   are read for it. Its payout closes even when the keepers directory cannot be
   listed. *)
let read_tasks ~sources (waiting : Candle_payout.waiting) (pass : Candle_payout.pass) =
  match pass.linked_task_ids with
  | [] -> Ok []
  | _ :: _ -> sources.task_lookups ~goal_id:waiting.goal_id pass.linked_task_ids
;;

let write_candidates ~released ~fenced ~sources ~keeper_snapshot ~now ~base_path (waiting : Candle_payout.waiting)
  (pass : Candle_payout.pass) =
  let* tasks = read_tasks ~sources waiting pass in
  let issues = Candle_payout.window_issues
      ~goal_created_at:pass.goal_created_at ~confirmed_at:waiting.confirmed_at tasks in
  let durable_issue = List.exists (function
    | Candle_payout.Same_second _ | Candle_payout.Reversed_window _ -> true
    | Candle_payout.Task_missing _ | Candle_payout.Task_unobserved _
    | Candle_payout.Unfenced_nonterminal _ -> false) issues in
  let still_needed events =
    Candle_payout.current_pass_of waiting events = Ok pass
    && Option.is_none (Candle_payout.candidates_of waiting events)
    && Option.is_none (Candle_payout.held_window_of waiting events) in
  if durable_issue && released then (
    (* RFC-0512: the release gave this payout one fresh read. The fresh read
       reproduced the same permanent ambiguity, so the payout closes for
       nobody instead of holding again. *)
    let* at = Candle_stamp.at ~now in
    let* written =
      append_when_still_open ~base_path waiting ~still_needed
        [ unattributed_row ~at waiting Candle_event.Window_released ] in
    Ok (match written with
      | Written -> Wrote_unattributed {goal_id=waiting.goal_id}
      | Not_written -> Superseded {goal_id=waiting.goal_id}))
  else if durable_issue then (
    (* Preserve the time observation even when the Keeper directory is down. *)
    let is_keeper = match keeper_snapshot with Ok value -> Some value | Error _ -> None in
    let tasks = Candle_payout.classify_fragments ~is_keeper tasks in
    let task_keepers = Candle_payout.classify_keepers ~is_keeper tasks in
    let* at = Candle_stamp.at ~now in
    let row = {Candle_event.at; body=Candle_event.Candidate_window_held
        {goal_id=waiting.goal_id; request_id=waiting.request_id;
         verification_run_id=waiting.verification_run_id; passed_at=waiting.passed_at;
         confirmed_at=waiting.confirmed_at; tasks; task_keepers}} in
    let* written = append_when_still_open ~base_path waiting ~still_needed [row] in
    Ok (match written with
      | Written -> Held_window {goal_id=waiting.goal_id; issues; recorded=true}
      | Not_written -> Superseded {goal_id=waiting.goal_id}))
  else if issues <> [] then Ok (Waiting_task {goal_id=waiting.goal_id; issues})
  else (
    let* is_keeper = match tasks with
      | [] -> Ok (fun (_ : string) -> false)
      | _ :: _ -> keeper_snapshot in
    let* decided = Candle_payout.decide_candidates ~goal_created_at:pass.goal_created_at
        ~confirmed_at:waiting.confirmed_at ~is_keeper tasks
      |> Result.map_error (fun issues -> String.concat "; " (List.map Candle_payout.window_issue_to_string issues)) in
    let* at = Candle_stamp.at ~now in
    let rows = candidates_row ~fenced ~at waiting tasks decided
      :: (if no_candidate_keepers decided then [ unattributed_row ~at waiting Candle_event.No_candidates ] else []) in
    let* written = append_when_still_open ~base_path waiting ~still_needed rows in
    Ok (match written, no_candidate_keepers decided with
      | Written, true -> Wrote_unattributed { goal_id = waiting.goal_id }
      | Written, false -> Wrote_candidates { goal_id = waiting.goal_id }
      | Not_written, (true | false) -> Superseded { goal_id = waiting.goal_id }))
;;

let prepare ~sources ~now ~config events (waiting : Candle_payout.waiting) =
  let base_path = config.Workspace_utils_backend_setup.base_path in
  match Candle_payout.current_pass_of waiting events with
  | Error detail -> Error detail
  | Ok pass ->
    let issues tasks = Candle_payout.window_issues
        ~goal_created_at:pass.goal_created_at ~confirmed_at:waiting.confirmed_at tasks in
    (match Candle_payout.held_window_of waiting events with
     | Some held -> Ok (Held_window {goal_id=waiting.goal_id; issues=issues held.tasks; recorded=false})
     | None ->
       (match Candle_payout.candidate_observations_of waiting events,
              Candle_payout.candidates_of waiting events with
        | Some (tasks, provenance), Some _
          when Candle_payout.observation_issues ~provenance
                 ~goal_created_at:pass.goal_created_at ~confirmed_at:waiting.confirmed_at tasks <> [] ->
          Ok (Held_window {goal_id=waiting.goal_id;
            issues=Candle_payout.observation_issues ~provenance
              ~goal_created_at:pass.goal_created_at ~confirmed_at:waiting.confirmed_at tasks;
            recorded=false})
        | Some _, Some decided when no_candidate_keepers decided ->
          close_without_keepers ~now ~base_path waiting
        | Some _, Some _ -> Ok (Already_prepared { goal_id = waiting.goal_id })
        | None, None when pass.linked_task_ids = [] ->
          write_candidates ~released:(Candle_payout.released_of waiting events)
            ~fenced:false ~sources ~keeper_snapshot:(Ok (fun _ -> false))
            ~now ~base_path waiting pass
        | None, None ->
          (* Directory enumeration does not belong inside the backlog fence.
             An unavailable registry remains unknown if the Task read shows a
             boundary; an ordinary candidate set still requires a snapshot. *)
          let keeper_snapshot =
            try sources.is_keeper () with
            | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
            | exn -> Error ("Keeper registry failed: " ^ Printexc.to_string exn) in
          let lock_path = Workspace_backlog.backlog_lock_path config in
          (match Workspace_utils_ops.try_with_file_lock config lock_path (fun () ->
             Workspace_utils_ops.commit_under_held_lease config lock_path (fun () ->
               write_candidates ~released:(Candle_payout.released_of waiting events)
                 ~fenced:true ~sources ~keeper_snapshot ~now ~base_path waiting pass)) with
           | Workspace_utils_ops.Lock_contended -> Error "Task backlog is busy; candidate preparation will retry"
           | Lock_unavailable detail -> Error ("Task backlog lock unavailable: " ^ detail)
           | Lock_acquired (Error refusal) -> Error (Workspace_utils_ops.lease_commit_refusal_to_string refusal)
           | Lock_acquired (Ok outcome) -> outcome)
        | None, Some _ | Some _, None -> Error "candidate observation is incomplete"))
;;

let report = function
  | Wrote_candidates { goal_id } ->
    Log.Candle.info "candidates written goal_id=%s" goal_id
  | Wrote_unattributed { goal_id } ->
    Log.Candle.info "no keeper to pay, payout closed goal_id=%s" goal_id
  | Already_prepared _ | Superseded _ -> ()
  | Held_window {goal_id; issues; recorded=true} ->
    Log.Candle.warn "payout window held goal_id=%s: %s" goal_id
      (String.concat "; " (List.map Candle_payout.window_issue_to_string issues))
  | Held_window {recorded=false; _} -> ()
  | Waiting_task {goal_id; issues} ->
    Log.Candle.warn "payout awaits Task evidence goal_id=%s: %s" goal_id
      (String.concat "; " (List.map Candle_payout.window_issue_to_string issues))
  | Retry_later { goal_id; detail } ->
    Log.Candle.warn "payout not prepared, will retry goal_id=%s: %s" goal_id detail
;;

let drain_with ~sources ~now ~(config : Workspace_utils_backend_setup.config) =
  let base_path = config.base_path in
  match Candle_status.for_recording ~base_path with
  | Candle_status.Recording_off | Recording_disabled _ | Recording_unavailable _ -> Ok []
  | Candle_status.Recording_enabled _ ->
    let* view =
      Result.map_error Candle_ledger.read_error_to_string (Candle_ledger.read ~base_path)
    in
    let events = Candle_ledger.events view in
    let outcomes =
      List.map
        (fun (waiting : Candle_payout.waiting) ->
           (* An exception from a source is one payout's failure. Letting it end
              the pass would leave the payouts after it unprepared on every
              pass, because the order is fixed. *)
           let outcome =
             match prepare ~sources ~now ~config events waiting with
             | Ok outcome -> outcome
             | Error detail -> Retry_later { goal_id = waiting.goal_id; detail }
             | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
             | exception exn ->
               Retry_later
                 { goal_id = waiting.goal_id
                 ; detail = "unexpected exception: " ^ Printexc.to_string exn
                 }
           in
           report outcome;
           outcome)
        (Candle_payout.waiting events)
    in
    Ok outcomes
;;

let drain_once ~now (config : Workspace_utils_backend_setup.config) =
  drain_with ~sources:(real_sources config) ~now ~config
;;
