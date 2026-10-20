type ready = { instance_id : string; owner_pid : int; child_pid : int }
let valid_instance value = String.trim value<>"" && not (String.contains value '\000')
let ready_to_json value = `Assoc ["version",`Int 1;"instance_id",`String value.instance_id;
  "owner_pid",`Int value.owner_pid;"child_pid",`Int value.child_pid]
let ready_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["child_pid";"instance_id";"owner_pid";"version"] ->
    (match List.assoc_opt "version" fields,List.assoc_opt "instance_id" fields,
      List.assoc_opt "owner_pid" fields,List.assoc_opt "child_pid" fields with
     | Some (`Int 1),Some (`String instance_id),Some (`Int owner_pid),Some (`Int child_pid)
       when valid_instance instance_id && owner_pid>1 && child_pid>1 && owner_pid<>child_pid ->
       Ok {instance_id;owner_pid;child_pid}
     | _ -> Error "invalid browser process bootstrap receipt")
  | _ -> Error "invalid browser process bootstrap fields"
type error = Invalid_instance | Invalid_command | Invalid_grace
  | Not_group_leader | Group_unavailable of string
let error_to_string = function
  | Invalid_instance -> "browser process instance must be nonblank without NUL"
  | Invalid_command -> "browser process command must name an absolute executable without NUL"
  | Invalid_grace -> "browser process cleanup grace must be finite and non-negative"
  | Not_group_leader -> "browser process owner must lead its own foreground group"
  | Group_unavailable detail -> "browser process group cannot be observed: " ^ detail
let ( let* ) = Result.bind
let run ~env ~instance_id ~command ~grace_seconds ~on_ready =
  let* ()=if valid_instance instance_id then Ok () else Error Invalid_instance in
  let* ()=match command with
    | executable::arguments when not (Filename.is_relative executable)
        && List.for_all (fun value -> not (String.contains value '\000')) (executable::arguments) -> Ok ()
    | [] | _::_ -> Error Invalid_command in
  let* ()=if Float.is_finite grace_seconds && grace_seconds>=0. then Ok () else Error Invalid_grace in
  let pid=Unix.getpid () in
  let* group=Posix_spawn_detached.group_of_pid pid |> Result.map_error (fun detail -> Group_unavailable detail) in
  let* ()=if pid>1 && group=pid then Ok () else Error Not_group_leader in
  (* This PID stays occupied by the running owner through the final signal.
     No saved PID, command-line lookup or numeric orphan-signalling fallback. *)
  let finish () = Unix.kill (-pid) Sys.sigkill;exit 1 in
  Eio.Switch.run (fun sw ->
    Fun.protect ~finally:finish (fun () ->
      let stopping=Atomic.make false and changed=Eio.Condition.create () in
      List.iter (fun signal ->
        (* This dedicated owner never returns after admission. Restoring default
           handlers before group teardown would create a late-TERM orphan gap. *)
        ignore (Sys.signal signal (Sys.Signal_handle (fun _ ->
          Atomic.set stopping true;Eio.Condition.broadcast changed)))) [Sys.sigterm;Sys.sigint];
      let input=Eio.Path.open_in ~sw Eio.Path.(Eio.Stdenv.fs env / "/dev/null") in
      Eio.Switch.check sw;
      if Atomic.get stopping then finish ();
      let child=Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr ~stdin:input
        ~stdout:(Eio.Stdenv.stderr env) ~stderr:(Eio.Stdenv.stderr env) command in
      let ending=Eio.Fiber.first
          (fun () ->
            if not (Atomic.get stopping) then on_ready {instance_id;owner_pid=pid;child_pid=Eio.Process.pid child};
            Eio.Fiber.await_cancel ())
          (fun () -> Eio.Fiber.first
            (fun () -> ignore (Eio.Process.await child);`Child_ended)
            (fun () -> Eio.Fiber.first
              (fun () ->
                (try ignore (Eio.Flow.single_read (Eio.Stdenv.stdin env) (Cstruct.create 1)) with End_of_file -> ());
                `Stop_requested)
              (fun () -> Eio.Condition.loop_no_mutex changed (fun () ->
                if Atomic.get stopping then Some `Stop_requested else None)))) in
      (match ending with
      | `Child_ended -> ()
      | `Stop_requested ->
        (* The owner remains the group leader, including when the child exits
           first. TERM reaches descendants too; the full grace belongs to them.
           This bounds resource shutdown, never page or model work. *)
        Unix.kill (-pid) Sys.sigterm;
        Eio.Time.sleep (Eio.Stdenv.clock env) grace_seconds);
      Ok ()))
