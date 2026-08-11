let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats ->
    (match stats.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun name -> remove_tree (Filename.concat path name));
       Unix.rmdir path
     | _ -> Unix.unlink path)
;;
