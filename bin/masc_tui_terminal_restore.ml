type outcome =
  | Restored
  | Terminal_gone of Unix.error

let put_back ~set =
  match set () with
  | () -> Restored
  | exception Unix.Unix_error (((Unix.ENOTTY | Unix.EIO) as gone), _, _) ->
    Terminal_gone gone

let finish_after_restore ~restore ~finish =
  match restore () with
  | Restored -> finish ()
  | Terminal_gone _ -> ()
