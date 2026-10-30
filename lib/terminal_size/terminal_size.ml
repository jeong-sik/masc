(* [Unix.file_descr] is an int on every platform this builds for, which is the
   representation the stub reads with [Int_val]; declaring the external over
   the abstract type keeps the conversion in C instead of an [Obj.magic]
   here. *)
external size_of_fd : Unix.file_descr -> (int * int) option
  = "masc_terminal_size_of_fd"

(* Three descriptors because any one of them can be redirected while the others
   still name the terminal: a TUI started with its output piped to a file still
   has the terminal on stdin, and one started under a logger keeps it on stdout.
   The first that answers wins; if none does, the caller has no terminal to
   measure and must say so rather than invent a size. *)
let rec first_measured = function
  | [] -> None
  | fd :: rest ->
    (match size_of_fd fd with
     | Some _ as size -> size
     | None -> first_measured rest)
;;

(* /dev/tty names the controlling terminal whatever the three descriptors were
   pointed at, so it answers the case they cannot: a TUI whose output, input,
   and errors are all redirected still has a terminal, and masc#30187 hit
   exactly that after masc#30160 sent stderr to a file. Opening it can fail --
   a process in its own session has no controlling terminal -- and that failure
   is an answer of [None], not an error to raise at a caller who only asked how
   wide the window is. *)
let controlling_terminal_size () =
  match Unix.openfile "/dev/tty" [ Unix.O_RDONLY ] 0 with
  | exception Unix.Unix_error _ -> None
  | fd -> Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> size_of_fd fd)
;;

let get () =
  match first_measured [ Unix.stdout; Unix.stdin; Unix.stderr ] with
  | Some _ as size -> size
  | None -> controlling_terminal_size ()
;;
