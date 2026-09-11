let rec wait pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> Ok ()
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Error ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let capture = function
  | [] -> Error ()
  | executable :: _ as argv ->
    try
      let reader, writer = Unix.pipe ~cloexec:true () in
      let spawned = try Ok (Unix.create_process executable (Array.of_list argv)
        Unix.stdin writer Unix.stderr) with Unix.Unix_error _ -> Error () in
      Unix.close writer;
      match spawned with
      | Error () -> Unix.close reader; Error ()
      | Ok pid ->
        let channel = Unix.in_channel_of_descr reader in
        let output = Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
          try Ok (In_channel.input_all channel) with Sys_error _ -> Error ()) in
        (* An output read failure must still reap this child. There is no forced
           termination policy hidden in an installer I/O helper. *)
        let result = wait pid in
        (match result, output with Ok (), Ok body -> Ok body | _ -> Error ())
    with Unix.Unix_error _ -> Error ()
