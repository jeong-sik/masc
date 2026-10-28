module Queue = Keeper_memory_admission_queue
module Current = Keeper_memory_os_current

type judgment_result = Committed | Awaiting_evidence | Deferred of string | Input_size_refused of string
type outcome = Keeper_librarian_admission_owner.outcome =
  | Disabled | Idle | Recheck_new_input | Settled of {has_more : bool}
  | Pending of string | Addon_unattached of {pending : int} | Unavailable of string

let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f

(* The runtime's typed capacity evidence, not a candidate-count threshold or a
   prose error match. A walk that also met a failure a smaller range meets the
   same way (a quota, an outage, an operator refusal) is deferred whole rather
   than splitting it into one request per part. *)
let judgment_of_not_committed (reason : Keeper_librarian_runtime.not_committed) =
  match reason.input_capacity_evidence with
  | Keeper_librarian_runtime.Input_capacity_refused
    when not reason.smaller_range_meets_same_failure -> Input_size_refused reason.detail
  | Input_capacity_refused | No_input_capacity_refusal -> Deferred reason.detail

(* One pass can report [not_committed] more than once: the runtime reports the
   failure it saw and a later raise in the same pass reports again with no
   cause. A confirmed capacity refusal is evidence about the input, not about
   the last report, so a later report without that evidence cannot retract it.
   That includes a later report of a quota or outage: the batch still splits,
   and if that failure persists its first part defers the pass, so the cost is
   one or two more requests, not a loop. *)
let keep_strongest_judgment current reason =
  match current, judgment_of_not_committed reason with
  | Input_size_refused _, Deferred _ -> current
  | (Committed, next) | (Awaiting_evidence, next) | (Deferred _, next)
  | (Input_size_refused _, next) -> next

let run_with ~keepers_dir ~keeper_name ~judge =
  let read () = io (fun () -> Queue.read_pending ~keepers_dir ~keeper_id:keeper_name) in
  let acknowledge () = io (fun () -> Queue.acknowledge_committed ~keepers_dir ~keeper_id:keeper_name) in
  match acknowledge () with
  | Error detail -> Unavailable detail
  | Ok () ->
    match read () with
    | Error detail -> Unavailable detail
    | Ok None -> Idle
    | Ok (Some batch) ->
      let original_through = List.fold_left (fun highest (row : Queue.candidate) ->
        max highest row.sequence) 0 (Queue.candidates batch) in
      let finish ~committed ~pending_reason =
        match read () with
        | Error detail -> Unavailable detail
        | Ok remaining ->
          let has_more = match remaining with
            | None -> false
            | Some remaining -> List.exists (fun (row : Queue.candidate) ->
                row.sequence > original_through) (Queue.candidates remaining) in
          if committed then Settled {has_more}
          else if has_more then Recheck_new_input
          else Pending pending_reason in
      let rec evaluate ~committed ~pending_reason = function
        | [] -> finish ~committed ~pending_reason
        | part :: siblings ->
          match judge part with
          | Deferred detail -> finish ~committed ~pending_reason:detail
          | Awaiting_evidence ->
            evaluate ~committed ~pending_reason:"admission awaits further evidence" siblings
          | Input_size_refused detail ->
            (match Queue.split part with
             | None -> evaluate ~committed ~pending_reason:detail siblings
             | Some (left, right) ->
               evaluate ~committed ~pending_reason (left :: right :: siblings))
          | Committed ->
            (match acknowledge () with
             | Error detail -> Unavailable detail
             | Ok () ->
               match read () with
               | Error detail -> Unavailable detail
               | Ok remaining ->
                 let pending = match remaining with
                   | None -> [] | Some remaining -> Queue.candidates remaining in
                 let pending_ids = List.fold_left (fun ids (row : Queue.candidate) ->
                   Set_util.StringSet.add row.request_id ids) Set_util.StringSet.empty pending in
                 let consumed = List.exists (fun (row : Queue.candidate) ->
                   not (Set_util.StringSet.mem row.request_id pending_ids)) (Queue.candidates part) in
                 if not consumed then
                   Unavailable "admission commit has no matching consumed-input receipt"
                 else evaluate ~committed:true ~pending_reason siblings) in
      evaluate ~committed:false ~pending_reason:"admission remains pending" [batch]

let run = Keeper_librarian_admission_owner.run

module For_testing = struct
  let judgment_of_not_committed = judgment_of_not_committed
  let keep_strongest_judgment = keep_strongest_judgment
  let run_with = run_with
end
