(** RFC-0109 — Bounded subprocess discipline. *)

type outcome =
  | Done of Unix.process_status * string * string
  | Timeout of float

let run_argv_with_timeout ~clock ~process_mgr ~cwd ?env ?stdin_string
    ~timeout_s argv =
  let start = Eio.Time.now clock in
  Eio.Switch.run @@ fun proc_sw ->
  let stdout_buf = Buffer.create 4096 in
  let stderr_buf = Buffer.create 1024 in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw:proc_sw process_mgr in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw:proc_sw process_mgr in
  let stdin_source = Option.map Eio.Flow.string_source stdin_string in
  let proc =
    Eio.Process.spawn ~sw:proc_sw process_mgr ~cwd ?env
      ?stdin:stdin_source ~stdout:stdout_w ~stderr:stderr_w argv
  in
  (* Close the write ends in the parent so EOF propagates to the drain
     fibers once the child exits or is killed. *)
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let drain_and_await () =
    Eio.Fiber.both
      (fun () ->
        Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
        Eio.Flow.close stdout_r)
      (fun () ->
        Eio.Flow.copy stderr_r (Eio.Flow.buffer_sink stderr_buf);
        Eio.Flow.close stderr_r);
    let status =
      match Eio.Process.await proc with
      | `Exited n -> Unix.WEXITED n
      | `Signaled n -> Unix.WSIGNALED n
    in
    Done (status, Buffer.contents stdout_buf, Buffer.contents stderr_buf)
  in
  let timeout () =
    Eio.Time.sleep clock timeout_s;
    Timeout (Eio.Time.now clock -. start)
  in
  Eio.Fiber.first timeout drain_and_await
