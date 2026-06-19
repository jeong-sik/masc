type execution_kind =
  | Parallel_read
  | Sequential_workspace
  | Blocked

type t = {
  batch_id : string;
  execution_kind : execution_kind;
  jobs : Tool_job.t list;
}

let execution_kind_to_string = function
  | Parallel_read -> "parallel_read"
  | Sequential_workspace -> "sequential_workspace"
  | Blocked -> "blocked"

let is_parallel_read_candidate (job : Tool_job.t) =
  match job.approval with
  | Tool_job.Approved -> job.read_only && job.resource_keys = []
  | Tool_job.Pending _
  | Tool_job.Denied _ -> false

let is_blocked (job : Tool_job.t) =
  match job.approval with
  | Tool_job.Pending _
  | Tool_job.Denied _ -> true
  | Tool_job.Approved -> false

let make_batch execution_kind jobs =
  match jobs with
  | first :: _ -> { batch_id = first.Tool_job.batch_id; execution_kind; jobs }
  | [] -> invalid_arg "Tool_batch.make_batch: empty jobs"

let flush_parallel current acc =
  match current with
  | None -> acc
  | Some (_batch_id, jobs_rev) ->
    make_batch Parallel_read (List.rev jobs_rev) :: acc

let plan jobs =
  let rec loop current_parallel acc = function
    | [] -> List.rev (flush_parallel current_parallel acc)
    | job :: rest ->
      if is_blocked job then
        let acc = flush_parallel current_parallel acc in
        loop None (make_batch Blocked [ job ] :: acc) rest
      else if is_parallel_read_candidate job then
        (match current_parallel with
         | Some (batch_id, jobs_rev) ->
           if String.equal batch_id job.batch_id
           then loop (Some (batch_id, job :: jobs_rev)) acc rest
           else
             let acc = flush_parallel current_parallel acc in
             loop (Some (job.batch_id, [ job ])) acc rest
         | None -> loop (Some (job.batch_id, [ job ])) acc rest)
      else
        let acc = flush_parallel current_parallel acc in
        loop None (make_batch Sequential_workspace [ job ] :: acc) rest
  in
  loop None [] jobs
;;
