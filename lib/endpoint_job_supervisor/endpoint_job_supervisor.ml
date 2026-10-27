module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module O = Endpoint_job_output
module G = Endpoint_process_gate
let ( let* ) = Result.bind
type pipe_end = Child_stdin | Child_stdout | Child_stderr | Input_writer
type error =
  | Registry_error of R.error | Launch_error of L.error
  | Output_error of { stream : P.stream; cause : O.error }
  | Pipe_unavailable | Pipe_cleanup_failed of pipe_end list
  | Registry_cleanup_failed of File_lock_eio.durable_lock_error
  | Interrupted | Supervisor_failed
  | Publication_failed of Fs_compat.capability_write_error
  | Recovery_failed of string
  | Receipt_storage_unavailable
  | Result_encoding_failed of Endpoint_job_result.error
let pipe_tag = function
  | Child_stdin -> "child stdin" | Child_stdout -> "child stdout"
  | Child_stderr -> "child stderr" | Input_writer -> "stdin writer"
let error_to_string = function
  | Registry_error e -> R.error_to_string e | Launch_error e -> L.error_to_string e
  | Output_error {stream;cause} ->
    (match stream with P.Stdout -> "stdout: " | P.Stderr -> "stderr: ") ^ O.error_to_string cause
  | Pipe_unavailable -> "original stdio unavailable"
  | Pipe_cleanup_failed ends -> "original stdio cleanup failed: " ^ String.concat ", " (List.map pipe_tag ends)
  | Registry_cleanup_failed e -> File_lock_eio.durable_lock_error_to_string e
  | Interrupted -> "original job supervision interrupted"
  | Supervisor_failed -> "original job supervision failed"
  | Publication_failed e -> Fs_compat.capability_write_error_to_string e
  | Recovery_failed detail -> "result publication recovery: " ^ detail
  | Receipt_storage_unavailable -> "original result storage unavailable"
  | Result_encoding_failed e -> Endpoint_job_result.error_to_string e
exception Cleanup_failed of pipe_end list
type input_delivery = Written of int64 | Write_failed of { confirmed_prefix : int64 }
type settled = { physical_exit : G.exit_observation; stdin : input_delivery; stdout : O.seal; stderr : O.seal }
type result_receipt = { sha256 : P.Sha256.t; status : P.response; content : string }
type t = {
  owner : L.t;
  stdout : (O.t,error) result;
  stderr : (O.t,error) result;
  availability : (unit,error) result;
  done_ : (settled,error) result Eio.Promise.t;
  result : (result_receipt,error) result Eio.Promise.t;
}
type launch_outcome =
  | Not_performed of { error : error; pipe_cleanup_errors : pipe_end list }
  | Performed of { value : (t,error) result; registry_release_error : File_lock_eio.durable_lock_error option;
      pipe_cleanup_errors : pipe_end list }
let io f = try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> Error Pipe_unavailable
let original t = L.original t.owner
let availability t =
  let* ()=t.availability in
  match Eio.Promise.peek t.done_ with
  | Some (Error e) -> Error e
  | None | Some (Ok _) ->
    let* out=t.stdout in let* err=t.stderr in
    let* _=O.extent out |> Result.map_error (fun cause -> Output_error {stream=P.Stdout;cause}) in
    let* _=O.extent err |> Result.map_error (fun cause -> Output_error {stream=P.Stderr;cause}) in Ok ()
let await_settled t = Eio.Promise.await t.done_
let await_result t = Eio.Promise.await t.result
type observation = { settled : settled; status : P.response }
let physical_status (settled : settled) = match settled.physical_exit.status with
  | G.Exited code -> P.Exited code | G.Signaled signal -> P.Signaled signal
let terminal_phase record (settled : settled) =
  let observed=P.Termination_observed (physical_status settled) in
  if settled.stdout.byte_length<>0L || settled.stderr.byte_length<>0L then observed else
  let boundary=settled.physical_exit.boundary in
  match boundary.control with
  (* A failed channel may have cut the gate evidence short; only EOF backs a non-start. *)
  | G.Open | G.Failed _ -> observed
  | G.Ended -> (match boundary.preparation with
      | G.Rejected _ -> P.Not_started P.Launch_rejected
      | G.Pending | Ready -> (match boundary.decision with
          | G.Activate_requested -> observed
          | G.Undecided | Abort_requested ->
            match R.cancellation_state record with
            | R.Cancellation_requested -> P.Not_started P.Cancelled_before_activation
            | R.No_cancellation -> observed))
let status record (settled : settled) result : P.response =
  let sealed (seal : O.seal)=P.Sealed {byte_length=seal.byte_length;sha256=seal.sha256} in
  P.Status {original=P.original ~binding:(R.binding record) ~admission_id:(R.admission_id record);
    revision=R.revision record;phase=terminal_phase record settled;
    cancel_requested=(R.cancellation_state record=R.Cancellation_requested);
    result;stdout=sealed settled.stdout;stderr=sealed settled.stderr}
let observe_settled t settled =
  let* record=L.observe_original t.owner |> Result.map_error (fun e -> Launch_error e) in
  Ok ({settled;status=status record settled P.Result_pending},record)
let await_observation t =
  let* settled=await_settled t in
  let* observed,_=observe_settled t settled in Ok observed

type progress =
  | Awaiting_settlement of { stdout : P.extent; stderr : P.extent }
  | Physically_settled of observation
  | Publication_known of P.Sha256.t
type snapshot = { record : R.record; progress : progress }
let snapshot_with_hook ~after_original t =
  let* record=L.observe_original t.owner |> Result.map_error (fun e -> Launch_error e) in
  after_original ();
  let* progress=match Eio.Promise.peek t.result with
    | Some (Error e) -> Error e
    | Some (Ok receipt) -> Ok (Publication_known receipt.sha256)
    | None ->
      let* ()=t.availability in
      match Eio.Promise.peek t.done_ with
      | Some (Error e) -> Error e
      | Some (Ok settled) ->
        Ok (Physically_settled {settled;status=status record settled P.Result_pending})
      | None ->
        let extent stream capture =
          let* captured=capture in
          O.extent captured |> Result.map_error (fun cause -> Output_error {stream;cause}) in
        let* stdout=extent P.Stdout t.stdout in
        let* stderr=extent P.Stderr t.stderr in
        Ok (Awaiting_settlement {stdout;stderr}) in
  Ok {record;progress}
let snapshot t = snapshot_with_hook ~after_original:(fun () -> ()) t

let result_leaf=Endpoint_job_result.leaf
let receipt_io f = try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> Error Receipt_storage_unavailable
let cpu f = Domain_pool_ref.submit_cpu_or_inline f
let result_content (observation : observation) launch_id =
  let boundary=observation.settled.physical_exit.boundary in
  let preparation : Endpoint_job_result.preparation=match boundary.preparation with
    | G.Pending -> Pending
    | G.Ready -> Ready
    | G.Rejected {stage;error} ->
      (* Display evidence only. No reader may parse this diagnostic to infer
         exec, non-start, retry or signalling authority. *)
      Rejected {diagnostic=G.error_to_string (G.Child_rejected {stage;error})} in
  let input : Endpoint_job_result.input_delivery=match observation.settled.stdin with
    | Written bytes -> Accepted bytes | Write_failed {confirmed_prefix} -> Incomplete {confirmed_prefix} in
  let control : Endpoint_job_result.control=match boundary.control with
    | G.Open -> Open
    | G.Ended -> Ended
    | G.Failed failure ->
      (* Display evidence only, like a rejection diagnostic. *)
      Failed {diagnostic=G.error_to_string (G.control_failure_error failure)} in
  let gate : Endpoint_job_result.gate={preparation;decision=boundary.decision;control} in
  let process=Endpoint_job_result.Child {physical_exit=physical_status observation.settled;launch_id;input;gate} in
  Endpoint_job_result.encode ~status:observation.status ~process
  |> Result.map_error (fun e -> Result_encoding_failed e)

let verify_receipt ~sw ~storage ~root_stat ~content ~sha256 =
  let* opened=receipt_io (fun () -> Fs_compat.open_owned_reader ~sw ~parent:storage ~leaf:result_leaf) in
  let* reader=opened |> Result.map_error (fun _ -> Receipt_storage_unavailable) in
  let* initial=receipt_io (fun () -> Fs_compat.owned_reader_stat reader) in
  let* ()=if initial.kind=`Regular_file && initial.nlink=1L && initial.uid=root_stat.Eio.File.Stat.uid
      && initial.perm land 0o7777=0o400 && Optint.Int63.to_int64 initial.size=Int64.of_int (String.length content)
    then Ok () else Error Receipt_storage_unavailable in
  let stable (current : Eio.File.Stat.t) = {initial with atime=current.atime}=current in
  let validate () =
    let* root=receipt_io (fun () -> Eio.Path.stat ~follow:false storage) in
    let* held=receipt_io (fun () -> Fs_compat.owned_reader_stat reader) in
    let* canonical=receipt_io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(storage / result_leaf)) in
    if root.kind=`Directory && root.dev=root_stat.dev && root.ino=root_stat.ino
        && root.uid=root_stat.uid && root.perm land 0o7777=0o700 && stable held && stable canonical
      then Ok () else Error Receipt_storage_unavailable in
  let* ()=validate () in
  let bytes=Buffer.create (String.length content) in
  let rec read offset =
    if offset=String.length content then Ok (Buffer.contents bytes) else
    let* data=receipt_io (fun () -> Fs_compat.owned_reader_pread reader ~offset:(Int64.of_int offset)
      ~length:(min 65536 (String.length content-offset))) in
    if String.length data=0 then Error Receipt_storage_unavailable else (Buffer.add_string bytes data;read (offset+String.length data)) in
  let* actual=read 0 in
  let hash=cpu (fun () -> Agent_core_sha256.(to_hex (digest_string actual))) in
  let* ()=if actual=content && hash=P.Sha256.to_string sha256 then Ok () else Error Receipt_storage_unavailable in
  let* synced=receipt_io (fun () -> Fs_compat.sync_owned_reader ~parent:storage ~leaf:result_leaf reader) in
  let* ()=synced |> Result.map_error (fun _ -> Receipt_storage_unavailable) in
  let* ()=validate () in
  Ok validate

type result_read =
  | Observe_original | Open_storage | Reopen_stdout | Reopen_stderr
  | Validate_stdout | Validate_stderr | Refresh_after_publication
  | Cancel_held_original

let validation_stage = function P.Stdout -> Validate_stdout | P.Stderr -> Validate_stderr
let busy_stage ~default = function
  | Registry_error error -> if error=R.Busy then Some default else None
  | Launch_error error -> if error=L.Registry_error R.Busy then Some default else None
  | Output_error {stream;cause} ->
    if cause=O.Registry_error R.Busy then Some (validation_stage stream) else None
  | Pipe_unavailable | Pipe_cleanup_failed _ | Registry_cleanup_failed _ | Interrupted
  | Supervisor_failed | Result_encoding_failed _ | Publication_failed _ | Recovery_failed _
  | Receipt_storage_unavailable -> None

(* These are non-effecting, per-original reads. A competing mutation holds the
   same lease only temporarily; do not settle the job-owned result on Busy.
   Retrying each read separately also avoids replaying the exclusive receipt
   publication when the final refresh is contended. Pace retries with the
   existing file-lock interval and no timeout, while preserving cancellation.
   The held-startup cancellation waits here too: its Busy comes from the
   non-blocking lease before the body runs, so no claim was written and no
   tree was killed, and every other cancellation error is returned unchanged. *)
let await_result_read ~before_result_read ~on_result_read_busy stage f =
  before_result_read stage;
  let rec await () =
    match f () with
    | Ok value -> Ok value
    | Error error -> (match busy_stage ~default:stage error with
      | None -> Error error
      | Some current -> on_result_read_busy current;File_lock_eio.wait_after_contention ();await ()) in
  await ()

let publish_result ~before_result_read ~on_result_read_busy
    ~before_result_publish ~after_result_publish ~sw ~fs t settled =
  let read stage f=await_result_read ~before_result_read ~on_result_read_busy stage f in
  let* observation,record=read Observe_original (fun () -> observe_settled t settled) in
  let* launch_id=match R.launch_state record with
    | R.Requested launch_id -> Ok launch_id
    | R.Not_requested -> Error (Registry_error R.Stale_record) in
  let* opened=read Open_storage (fun () ->
    R.open_storage ~sw record |> Result.map_error (fun e -> Registry_error e)) in
  let storage=R.storage_path opened in
  let* root_stat=receipt_io (fun () -> Eio.Path.stat ~follow:true storage) in
  let* root_path=receipt_io (fun () -> Eio.Path.native_exn storage) in
  let* content=cpu (fun () -> result_content observation launch_id) in
  let hash=cpu (fun () -> Agent_core_sha256.(to_hex (digest_string content))) in
  let* sha256=P.Sha256.of_string hash |> Result.map_error (fun _ -> Receipt_storage_unavailable) in
  let* target=Fs_compat.capability_publication_target ~allowed_root_path:root_path
      ~allowed_root_device:root_stat.dev ~allowed_root_inode:root_stat.ino
      ~parent_components:[] ~target_leaf:result_leaf ~permissions:0o400
    |> Result.map_error (fun e -> Recovery_failed (Fs_compat.capability_publication_target_error_to_string e)) in
  before_result_publish ();
  let validate_once stream reader expected =
    let* actual=O.revalidate_sealed reader |> Result.map_error (fun cause -> Output_error {stream;cause}) in
    if actual=expected then Ok () else Error (Output_error {stream;cause=O.Invalid_storage}) in
  let validate stream reader expected =
    read (validation_stage stream) (fun () -> validate_once stream reader expected) in
  let with_reopened stream expected use =
    let stage=match stream with P.Stdout -> Reopen_stdout | P.Stderr -> Reopen_stderr in
    before_result_read stage;
    let rec attempt () =
      (* A failed reopen can already own descriptors. Close that attempt's
         switch before retrying; a successful reader stays alive through [use].
         In particular, never retry [use] after it has published the result. *)
      match Eio.Switch.run (fun reader_sw ->
        match O.reopen ~sw:reader_sw ~storage:opened ~stream with
        | Error cause -> if cause=O.Registry_error R.Busy then `Busy
          else `Done (Error (Output_error {stream;cause}))
        | Ok reader -> `Done (let* ()=validate stream reader expected in use reader)) with
      | `Busy -> on_result_read_busy stage;File_lock_eio.wait_after_contention ();attempt ()
      | `Done result -> result in
    attempt () in
  with_reopened P.Stdout settled.stdout (fun stdout ->
  with_reopened P.Stderr settled.stderr (fun stderr ->
  Eio.Switch.run (fun read_sw ->
  let validate_now stream reader expected =
    before_result_read (validation_stage stream);
    validate_once stream reader expected in
  let validate_outputs_once () =
    let* ()=validate_now P.Stdout stdout settled.stdout in
    validate_now P.Stderr stderr settled.stderr in
  let validate_outputs () =
    let rec attempt () =
      match validate_outputs_once () with
      | Ok () -> Ok ()
      | Error error -> (match busy_stage ~default:Refresh_after_publication error with
        | None -> Error error
        | Some stage ->
          (* If stderr waited, stdout must be checked again after that wait. *)
          on_result_read_busy stage;File_lock_eio.wait_after_contention ();attempt ()) in
    attempt () in
  let* ()=validate_outputs () in
  let* ()=L.with_storage_publication t.owner (fun () ->
    let* recovery=Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root:storage
      |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.registry_error_to_string e)) in
    let* outcome=Fs_compat.Publication_recovery.with_lane ~registry:recovery ~owner:"result" (fun recovery ->
      Fs_compat.create_capability_file_exclusive ~recovery ~parent:storage ~target content
      |> Result.map_error (fun e -> Publication_failed e))
      |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.lane_open_error_to_string e)) in
    match outcome with
    | Lane_released value -> value
    | Lane_release_failed {value;release_failure} ->
      let detail=Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure in
      Error (Recovery_failed (match value with Ok () -> detail | Error e -> error_to_string e ^ "; " ^ detail))) in
  after_result_publish ();
  let* validate_receipt=verify_receipt ~sw:read_sw ~storage ~root_stat ~content ~sha256 in
  let rec readiness () =
    let result=
      before_result_read Refresh_after_publication;
      let* current=R.refresh record |> Result.map_error (fun e -> Registry_error e) in
      let* ()=validate_outputs_once () in
      let* ()=validate_receipt () in
      Ok {sha256;status=status current settled (P.Result_ready sha256);content} in
    match result with
    | Ok receipt -> Ok receipt
    | Error error -> (match busy_stage ~default:Refresh_after_publication error with
      | None -> Error error
      | Some stage ->
        (* Re-read cancellation and both streams after any contested validation. *)
        on_result_read_busy stage;File_lock_eio.wait_after_contention ();readiness ()) in
  readiness ())))
let cancel t = L.cancel t.owner |> Result.map_error (fun e -> Launch_error e)
let await_quiescent t = L.await_quiescent t.owner |> Result.map_error (fun e -> Launch_error e)
let read_output t ~stream ~offset ~max_bytes =
  let* capture=match stream with P.Stdout -> t.stdout | P.Stderr -> t.stderr in
  O.read capture ~offset ~max_bytes |> Result.map_error (fun cause -> Output_error {stream;cause})

type pipes = {
  child_input : Eio_unix.source_ty Eio.Resource.t;
  input_writer : Eio_unix.sink_ty Eio.Resource.t;
  stdout_source : Eio_unix.source_ty Eio.Resource.t;
  child_output : Eio_unix.sink_ty Eio.Resource.t;
  stderr_source : Eio_unix.source_ty Eio.Resource.t;
  child_error : Eio_unix.sink_ty Eio.Resource.t;
}
let pipes ~sw = io (fun () ->
  let child_input,input_writer=Eio_unix.pipe sw in
  let stdout_source,child_output=Eio_unix.pipe sw in
  let stderr_source,child_error=Eio_unix.pipe sw in
  {child_input;input_writer;stdout_source;child_output;stderr_source;child_error})
let close_parent_ends pipes =
  let close name resource = match io (fun () -> Eio_unix.Fd.close (Eio_unix.Resource.fd resource)) with
    | Ok () -> None | Error _ -> Some name in
  (* Perform every independent close, even after an earlier close failed. *)
  let stdin=close Child_stdin pipes.child_input in
  let stdout=close Child_stdout pipes.child_output in
  let stderr=close Child_stderr pipes.child_error in
  List.filter_map Fun.id [stdin;stdout;stderr]
let reraised_after_close pipes ex bt =
  match close_parent_ends pipes with
  | [] -> Printexc.raise_with_backtrace ex bt
  | failures ->
    let ex,bt=Eio.Exn.combine (ex,bt) (Cleanup_failed failures,Printexc.get_callstack 16) in
    Printexc.raise_with_backtrace ex bt
let spawn ~sw ~fs ~cgroup_parent_path ~execution pipes intent =
  let call () =
    (* These ends are dedicated to the child; the controller only borrows and
       closes them. POSIX Eio pipes can be nonblocking, while ordinary programs
       need blocking stdio. Opposite controller ends have separate descriptions
       and retain their own Eio flags. No borrowed external FD is changed. *)
    Eio_unix.Fd.use_exn "child stdin mode" (Eio_unix.Resource.fd pipes.child_input) Unix.clear_nonblock;
    Eio_unix.Fd.use_exn "child stdout mode" (Eio_unix.Resource.fd pipes.child_output) Unix.clear_nonblock;
    Eio_unix.Fd.use_exn "child stderr mode" (Eio_unix.Resource.fd pipes.child_error) Unix.clear_nonblock;
    Eio_unix.Fd.use_exn "original stdin" (Eio_unix.Resource.fd pipes.child_input) (fun stdin ->
      Eio_unix.Fd.use_exn "original stdout" (Eio_unix.Resource.fd pipes.child_output) (fun stdout ->
        Eio_unix.Fd.use_exn "original stderr" (Eio_unix.Resource.fd pipes.child_error) (fun stderr ->
          L.launch_effect_workspace ~sw ~fs ~cgroup_parent_path ~execution ~stdin ~stdout ~stderr intent))) in
  match call () with
  | value -> value,close_parent_ends pipes
  | exception (Eio.Cancel.Cancelled _ as ex) -> reraised_after_close pipes ex (Printexc.get_raw_backtrace ())
  | exception ex -> reraised_after_close pipes ex (Printexc.get_raw_backtrace ())

let start_input ~sw pipes data =
  let done_,resolve=Eio.Promise.create () in
  let finish value=Eio.Promise.resolve resolve value in
  let rec send offset =
    if offset=String.length data then Written (Int64.of_int offset) else
    let chunk=Cstruct.of_string (String.sub data offset (min 65536 (String.length data-offset))) in
    let rec write consumed =
      let left=Cstruct.length chunk-consumed in
      if left=0 then send (offset+consumed) else
      match io (fun () -> Eio.Flow.single_write pipes.input_writer [Cstruct.sub chunk consumed left]) with
      | Ok n when n>0 && n<=left -> write (consumed+n)
      | Ok _ | Error _ -> Write_failed {confirmed_prefix=Int64.of_int (offset+consumed)} in
    write 0 in
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (match send 0 with
     | delivery ->
       let close=io (fun () -> Eio_unix.Fd.close (Eio_unix.Resource.fd pipes.input_writer)) in
       finish (match close with Ok () -> Ok delivery | Error _ -> Error (Pipe_cleanup_failed [Input_writer]))
     | exception (Eio.Cancel.Cancelled _ as ex) ->
       let bt=Printexc.get_raw_backtrace () in finish (Error Interrupted);Printexc.raise_with_backtrace ex bt
     | exception ex ->
       let bt=Printexc.get_raw_backtrace () in finish (Error Supervisor_failed);Printexc.raise_with_backtrace ex bt);
    `Stop_daemon);
  done_

let supervise ~before_result_read ~on_result_read_busy ~before_result_publish ~after_result_publish
    ~sw ~fs pipes owner ~registry_release_error ~pipe_cleanup_errors =
  let capture stream source=O.start ~sw ~fs ~owner ~stream ~source
    |> Result.map_error (fun cause -> Output_error {stream;cause}) in
  let stdout=capture P.Stdout pipes.stdout_source in
  let stderr=capture P.Stderr pipes.stderr_source in
  let input=start_input ~sw pipes (L.specification owner).stdin in
  let availability=
    let* ()=match L.activation owner with L.Requested -> Ok () | L.Held e -> Error (Launch_error e) in
    let* ()=match pipe_cleanup_errors with [] -> Ok () | ends -> Error (Pipe_cleanup_failed ends) in
    let* ()=match registry_release_error with None -> Ok () | Some e -> Error (Registry_cleanup_failed e) in
    let* _=stdout in let* _=stderr in Ok () in
  let done_,resolve=Eio.Promise.create () in
  let result,resolve_result=Eio.Promise.create () in
  let finished=Atomic.make false in
  let result_finished=Atomic.make false in
  let finish_result value=if Atomic.compare_and_set result_finished false true then Eio.Promise.resolve resolve_result value in
  let finish_raw value=if Atomic.compare_and_set finished false true then Eio.Promise.resolve resolve value in
  let finish value=
    finish_raw value;
    match value with Ok _ -> () | Error e -> finish_result (Error e) in
  let t={owner;stdout;stderr;availability;done_;result} in
  let daemon f =
    Eio.Switch.check sw;
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (match f () with
       | () -> ()
       | exception (Eio.Cancel.Cancelled _ as ex) ->
         let bt=Printexc.get_raw_backtrace () in finish (Error Interrupted);
         Printexc.raise_with_backtrace ex bt
       | exception ex ->
         let bt=Printexc.get_raw_backtrace () in finish (Error Supervisor_failed);
         Printexc.raise_with_backtrace ex bt);
      `Stop_daemon) in
  let settle () =
    let* physical_exit=await_quiescent t in
    let* stdin=Eio.Promise.await input in
    let* out=stdout in let* err=stderr in
    let* stdout=O.await_sealed out |> Result.map_error (fun cause -> Output_error {stream=P.Stdout;cause}) in
    let* stderr=O.await_sealed err |> Result.map_error (fun cause -> Output_error {stream=P.Stderr;cause}) in
    Ok {physical_exit;stdin;stdout;stderr} in
  let publish = function
    | Error e -> finish_result (Error e)
    | Ok settled -> finish_result (publish_result ~before_result_read ~on_result_read_busy
        ~before_result_publish ~after_result_publish ~sw ~fs t settled) in
  let watch_collectors () =
    let watch stream capture=daemon (fun () ->
      match capture with
      | Error e -> finish (Error e)
      | Ok captured -> (match O.await_sealed captured with
        | Ok _ -> () | Error cause -> finish (Error (Output_error {stream;cause})))) in
    watch P.Stdout stdout;watch P.Stderr stderr;
    daemon (fun () -> match Eio.Promise.await input with Ok _ -> () | Error e -> finish (Error e)) in
  (match availability with
   | Ok () ->
     daemon (fun () -> let settled=settle () in finish settled;publish settled);
     watch_collectors ()
   | Error e -> (match L.activation owner with
       | L.Requested -> finish (Error e)
       | L.Held _ ->
         (* The original startup failure remains observable. Its separate
            terminal result requires durable original cancellation, actual
            stop and complete original bytes; no effect is replayed. *)
         finish_raw (Error e);
         daemon (fun () ->
           let stopped=
             let* _=await_result_read ~before_result_read ~on_result_read_busy
               Cancel_held_original (fun () -> cancel t) in
             settle () in
           publish stopped);
         watch_collectors ()));
  t

let launch_with_hook ~before_result_read ~on_result_read_busy ~after_spawn ~before_result_publish
    ~after_result_publish ~sw ~fs ~cgroup_parent_path ~execution intent =
  Eio.Switch.check sw;
  match pipes ~sw with
  | Error error -> Not_performed {error;pipe_cleanup_errors=[]}
  | Ok pipes ->
    let result,pipe_cleanup_errors=spawn ~sw ~fs ~cgroup_parent_path ~execution pipes intent in
    match result with
    | R.Not_performed e -> Not_performed {error=Registry_error e;pipe_cleanup_errors}
    | R.Performed {value;release_error=registry_release_error} ->
      let value=match value with
        | Error e -> Error (Launch_error e)
        | Ok owner ->
          after_spawn owner;
          Ok (supervise ~before_result_read ~on_result_read_busy ~before_result_publish
            ~after_result_publish ~sw ~fs pipes owner ~registry_release_error ~pipe_cleanup_errors) in
      Performed {value;registry_release_error;pipe_cleanup_errors}

let launch_effect_workspace ~sw ~fs ~cgroup_parent_path ~execution intent =
  launch_with_hook ~after_spawn:(fun _ -> ()) ~before_result_publish:(fun () -> ())
    ~after_result_publish:(fun () -> ()) ~before_result_read:(fun _ -> ())
    ~on_result_read_busy:(fun _ -> ()) ~sw ~fs ~cgroup_parent_path ~execution intent
module For_testing = struct
  type nonrec result_read = result_read =
    | Observe_original | Open_storage | Reopen_stdout | Reopen_stderr
    | Validate_stdout | Validate_stderr | Refresh_after_publication
    | Cancel_held_original
  let launch_effect_workspace ?(before_result_read=fun _ -> ()) ?(on_result_read_busy=fun _ -> ())
      ~after_spawn ~before_result_publish ~after_result_publish ~sw ~fs ~cgroup_parent_path ~execution intent =
    launch_with_hook ~before_result_read ~on_result_read_busy ~after_spawn ~before_result_publish
      ~after_result_publish ~sw ~fs ~cgroup_parent_path ~execution intent
  let snapshot = snapshot_with_hook
end
