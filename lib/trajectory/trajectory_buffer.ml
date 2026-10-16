type receipt = bool Atomic.t

type item = { json : Yojson.Safe.t; receipt : receipt }

type writer_state =
  | Ready
  | Writing
  | Uncertain of Trajectory_persistence.issue

type t =
  { path : string
  ; mu : Stdlib.Mutex.t
  ; pending : item Queue.t
  ; mutable state : writer_state
  ; mutable references : int
  ; append : path:string -> Yojson.Safe.t list -> Trajectory_persistence.outcome
  }

type outcome =
  | Empty
  | Busy
  | Flushed of
      { rows : int
      ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
      }
  | Retryable_failure of Trajectory_persistence.issue
  | Indeterminate_failure of Trajectory_persistence.issue
  | Blocked of Trajectory_persistence.issue

let registry : (string, t) Hashtbl.t = Hashtbl.create 16
let registry_mu = Stdlib.Mutex.create ()
let with_writer writer f = Stdlib.Mutex.protect writer.mu f

let acquire_with_append ~append ~path =
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt registry path with
    | Some writer -> writer.references <- writer.references + 1; writer
    | None ->
      let writer =
        { path; mu=Stdlib.Mutex.create (); pending=Queue.create (); state=Ready
        ; references=1; append }
      in
      Hashtbl.add registry path writer;
      writer)
;;

let acquire ~path = acquire_with_append ~append:Trajectory_persistence.append ~path

let retire_unreferenced writer =
  Stdlib.Mutex.protect registry_mu (fun () ->
    if writer.references = 0
       && with_writer writer (fun () ->
            match writer.state with
            | Ready -> Queue.is_empty writer.pending
            | Writing | Uncertain _ -> false)
    then match Hashtbl.find_opt registry writer.path with
      | Some current when current == writer -> Hashtbl.remove registry writer.path
      | Some _ | None -> ())
;;

let release writer =
  Stdlib.Mutex.protect registry_mu (fun () ->
    if writer.references <= 0 then invalid_arg "trajectory writer released twice";
    writer.references <- writer.references - 1);
  retire_unreferenced writer
;;

let enqueue writer json =
  let receipt = Atomic.make false in
  with_writer writer (fun () -> Queue.add {json; receipt} writer.pending);
  receipt
;;

let is_durable = Atomic.get
let depth writer = with_writer writer (fun () -> Queue.length writer.pending)

let cancellation_issue exception_ =
  Trajectory_persistence.
    { failure=Raised {exception_; backtrace=Printexc.get_raw_backtrace ()}
    ; cleanup_failure=None }
;;

let flush_protected writer =
  let selected = with_writer writer (fun () ->
    match writer.state with
    | Uncertain issue -> Error (Blocked issue)
    | Writing -> Error Busy
    | Ready ->
      if Queue.is_empty writer.pending then Error Empty
      else begin
        let batch = Queue.fold (fun acc row -> row :: acc) [] writer.pending |> List.rev in
        writer.state <- Writing;
        Ok batch
      end)
  in
  match selected with
  | Error outcome -> outcome
  | Ok batch ->
    let written =
      match writer.append ~path:writer.path (List.map (fun row -> row.json) batch) with
      | outcome -> outcome
      | exception exception_ ->
        let issue = cancellation_issue exception_ in
        with_writer writer (fun () -> writer.state <- Uncertain issue);
        (* Unexpected writer exceptions cannot authorize a retry. In
           particular cancellation still propagates after preserving ownership. *)
        (match exception_ with
         | Eio.Cancel.Cancelled _ -> raise exception_
         | _ -> Trajectory_persistence.Indeterminate issue)
    in
    let outcome = with_writer writer (fun () ->
      match written with
      | Trajectory_persistence.Durable {cleanup_failure} ->
        List.iter (fun expected ->
          let actual = Queue.take writer.pending in
          if actual != expected then invalid_arg "trajectory FIFO ownership changed";
          Atomic.set actual.receipt true) batch;
        writer.state <- Ready;
        Flushed {rows=List.length batch; cleanup_failure}
      | Trajectory_persistence.Not_committed issue ->
        writer.state <- Ready;
        Retryable_failure issue
      | Trajectory_persistence.Indeterminate issue ->
        writer.state <- Uncertain issue;
        Indeterminate_failure issue)
    in
    retire_unreferenced writer;
    outcome
;;

let flush writer =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> flush_protected writer
  | Fs_compat.Eio_fiber ->
    Eio.Fiber.check ();
    (* Ownership may leave memory only after the actual fsync acknowledgement.
       Defer cancellation through that acknowledgement and its publication. *)
    Eio.Cancel.protect (fun () -> flush_protected writer)
;;

let flush_all () =
  let writers = Stdlib.Mutex.protect registry_mu (fun () ->
    Hashtbl.fold (fun _ writer acc -> writer :: acc) registry []) in
  List.map (fun writer -> writer, flush writer) writers
;;

let outcome_label = function
  | Empty -> "empty"
  | Busy -> "in_progress"
  | Flushed _ -> "committed"
  | Retryable_failure _ -> "not_committed"
  | Indeterminate_failure _ -> "indeterminate"
  | Blocked _ -> "blocked"
;;

module For_testing = struct
  let acquire_with_append = acquire_with_append
end
