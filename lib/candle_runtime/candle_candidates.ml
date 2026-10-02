(* See candle_candidates.mli. *)

let ( let* ) = Result.bind

type outcome =
  | Wrote_candidates of { goal_id : string }
  | Wrote_unattributed of { goal_id : string }
  | Already_prepared of { goal_id : string }
  | Superseded of { goal_id : string }
  | Retry_later of { goal_id : string; detail : string }

type sources =
  { task_lookups :
      goal_id:string -> string list -> ((string * Candle_event.task_lookup) list, string) result
  ; is_keeper : unit -> (string -> bool, string) result
  }

let real_sources config =
  { task_lookups = (fun ~goal_id task_ids -> Candle_tasks.lookups config ~goal_id task_ids)
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
  Result.map_error
    (Candle_ledger.update_error_to_string Fun.id)
    (Candle_ledger.update ~base_path (fun view ->
       let events = Candle_ledger.events view in
       match Candle_payout.state ~goal_id:waiting.goal_id events with
       | Candle_payout.Waiting open_payout
         when String.equal open_payout.request_id waiting.request_id
              && String.equal open_payout.verification_run_id waiting.verification_run_id
              && still_needed events ->
         Ok (rows, Written)
       | Candle_payout.Waiting _ | Candle_payout.No_obligation | Candle_payout.Failed _ | Candle_payout.Settled ->
         Ok ([], Not_written)))
;;

let candidates_row ~at (waiting : Candle_payout.waiting) tasks (decided : Candle_payout.candidates) =
  { Candle_event.at
  ; body =
      Candle_event.Candidates
        { goal_id = waiting.goal_id
        ; request_id = waiting.request_id
        ; verification_run_id = waiting.verification_run_id
        ; tasks
        ; candidate_task_ids = decided.candidate_task_ids
        ; candidate_keepers = decided.candidate_keepers
        ; candidate_task_keepers = decided.candidate_task_keepers
        }
  }
;;

let unattributed_row ~at (waiting : Candle_payout.waiting) =
  { Candle_event.at
  ; body =
      Candle_event.Unattributed
        { goal_id = waiting.goal_id
        ; request_id = waiting.request_id
        ; verification_run_id = waiting.verification_run_id
        ; reason = Candle_event.No_candidates
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
      [ unattributed_row ~at waiting ]
  in
  Ok
    (match written with
     | Written -> Wrote_unattributed { goal_id = waiting.goal_id }
     | Not_written -> Superseded { goal_id = waiting.goal_id })
;;

(* A Goal that linked no Task names nobody, so neither the Tasks nor the Keepers
   are read for it. Its payout closes even when the keepers directory cannot be
   listed. *)
let read_tasks_and_keepers ~sources (waiting : Candle_payout.waiting) (pass : Candle_payout.pass) =
  match pass.linked_task_ids with
  | [] -> Ok ([], fun (_ : string) -> false)
  | _ :: _ ->
    let* tasks = sources.task_lookups ~goal_id:waiting.goal_id pass.linked_task_ids in
    let* is_keeper = sources.is_keeper () in
    Ok (tasks, is_keeper)
;;

let write_candidates ~sources ~now ~base_path (waiting : Candle_payout.waiting)
  (pass : Candle_payout.pass) =
  let* tasks, is_keeper = read_tasks_and_keepers ~sources waiting pass in
  let decided =
    Candle_payout.decide_candidates
      ~goal_created_at:pass.goal_created_at
      ~confirmed_at:waiting.confirmed_at
      ~is_keeper
      tasks
  in
  let* at = Candle_stamp.at ~now in
  let rows =
    candidates_row ~at waiting tasks decided
    :: (if no_candidate_keepers decided then [ unattributed_row ~at waiting ] else [])
  in
  let* written =
    append_when_still_open
      ~base_path
      waiting
      ~still_needed:(fun events -> Option.is_none (Candle_payout.candidates_of waiting events))
      rows
  in
  Ok
    (match written, no_candidate_keepers decided with
     | Written, true -> Wrote_unattributed { goal_id = waiting.goal_id }
     | Written, false -> Wrote_candidates { goal_id = waiting.goal_id }
     | Not_written, (true | false) -> Superseded { goal_id = waiting.goal_id })
;;

let prepare ~sources ~now ~base_path events (waiting : Candle_payout.waiting) =
  match Candle_payout.pass_of waiting events with
  | None -> Error "no Snapshot names the confirmed pass, so the Tasks it linked are unknown"
  | Some pass ->
    (match Candle_payout.candidates_of waiting events with
     | Some decided when no_candidate_keepers decided -> close_without_keepers ~now ~base_path waiting
     | Some _ -> Ok (Already_prepared { goal_id = waiting.goal_id })
     | None -> write_candidates ~sources ~now ~base_path waiting pass)
;;

let report = function
  | Wrote_candidates { goal_id } ->
    Log.Misc.info "candle: candidates written goal_id=%s" goal_id
  | Wrote_unattributed { goal_id } ->
    Log.Misc.info "candle: no keeper to pay, payout closed goal_id=%s" goal_id
  | Already_prepared _ | Superseded _ -> ()
  | Retry_later { goal_id; detail } ->
    Log.Misc.warn "candle: payout not prepared, will retry goal_id=%s: %s" goal_id detail
;;

let drain_with ~sources ~now ~base_path =
  match Candle_status.current ~base_path with
  | Candle_config.Off | Candle_config.Disabled _ -> Ok []
  | Candle_config.Enabled _ ->
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
             match prepare ~sources ~now ~base_path events waiting with
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
  drain_with ~sources:(real_sources config) ~now ~base_path:config.base_path
;;
