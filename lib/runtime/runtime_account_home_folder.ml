(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

let directory ~private_ path =
  let stat = Unix.lstat path in
  if stat.st_kind = Unix.S_DIR && stat.st_uid = Unix.geteuid ()
     && stat.st_perm land (if private_ then 0o077 else 0o022) = 0
  then Ok () else Error "The selected account path must be an owned, protected directory."

(* A failure of the close after a failure of the sync is dropped: the first
   failure is the one reported. *)
let sync_folder path =
  let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  match Unix.fsync fd with
  | () -> Unix.close fd
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace

let child parent leaf =
  let path = Filename.concat parent leaf in
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let* () = directory ~private_:true path in
  sync_folder parent;
  Ok path

(* Each directory on the way is made from the spelling of the layout, so the
   home made here is the home every later reader computes. *)
let make ~runtime_root ~account_id ~client =
  let* home = Runtime_account_home_layout.home ~runtime_root client ~account_id in
  let client_root = Filename.dirname home in
  let clients = Filename.dirname client_root in
  let root = Filename.dirname clients in
  let* () = directory ~private_:false root in
  let* (_ : string) = child root (Filename.basename clients) in
  let* (_ : string) = child clients (Filename.basename client_root) in
  child client_root account_id
