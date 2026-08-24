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
let get () =
  let rec first = function
    | [] -> None
    | fd :: rest ->
      (match size_of_fd fd with
       | Some _ as size -> size
       | None -> first rest)
  in
  first [ Unix.stdout; Unix.stdin; Unix.stderr ]
;;
