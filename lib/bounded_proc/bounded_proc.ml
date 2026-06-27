(** RFC-0109 — Bounded subprocess discipline. *)

type outcome =
  | Done of Unix.process_status * string * string
  | Timeout of timeout

and timeout =
  { argv : string list
  ; timeout_s : float
  ; elapsed_s : float
  ; stdout : string
  ; stderr : string
  }

let ns_per_s = 1_000_000_000.0

let seconds_of_span span = Mtime.Span.to_float_ns span /. ns_per_s

let timeout_payload ~mono_clock ~start ~argv ~timeout_s ~stdout_buf ~stderr_buf =
  { argv
  ; timeout_s
  ; elapsed_s = seconds_of_span (Mtime.span start (Eio.Time.Mono.now mono_clock))
  ; stdout = Buffer.contents stdout_buf
  ; stderr = Buffer.contents stderr_buf
  }

let run_argv_with_timeout ~mono_clock ~process_mgr ~cwd ?env ?stdin_string
    ~timeout_s argv =
  let start = Eio.Time.Mono.now mono_clock in
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
    Eio.Time.Mono.sleep mono_clock timeout_s;
    Timeout
      (timeout_payload ~mono_clock ~start ~argv ~timeout_s ~stdout_buf
         ~stderr_buf)
  in
  Eio.Fiber.first timeout drain_and_await
