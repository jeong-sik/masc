(* See heap_roots.mli for what a reading means and what the walk costs. *)

type measurement =
  | Words of int
  | Absent
  | Failed of string

type reading =
  { name : string
  ; measurement : measurement
  ; walk_ms : float
  }

type root =
  { root_name : string
  ; value : unit -> Obj.t option
  }

(* Newest first; readers reverse. A CAS loop keeps registration lock-free and
   correct from any domain. *)
let roots : root list Atomic.t = Atomic.make []

let register ~name value =
  let rec attempt () =
    let current = Atomic.get roots in
    if List.exists (fun root -> String.equal root.root_name name) current
    then Error `Duplicate
    else if Atomic.compare_and_set roots current ({ root_name = name; value } :: current)
    then Ok ()
    else attempt ()
  in
  attempt ()
;;

let registered () = List.rev_map (fun root -> root.root_name) (Atomic.get roots)
let clear_for_tests () = Atomic.set roots []

let bits_per_byte = 8
let words_to_bytes words = words * (Sys.word_size / bits_per_byte)
let milliseconds_per_second = 1000.0

let measure_one ~now root =
  let started = now () in
  let measurement =
    match root.value () with
    | None -> Absent
    | Some value ->
      (match Obj.reachable_words value with
       | words -> Words words
       | exception exn -> Failed (Printexc.to_string exn))
    | exception exn -> Failed (Printexc.to_string exn)
  in
  { name = root.root_name
  ; measurement
  ; walk_ms = (now () -. started) *. milliseconds_per_second
  }
;;

let measure ~now () = List.rev_map (measure_one ~now) (Atomic.get roots)

let reading_to_yojson reading : Yojson.Safe.t =
  let status =
    match reading.measurement with
    | Words words ->
      [ "status", `String "measured"
      ; "words", `Int words
      ; "bytes", `Int (words_to_bytes words)
      ]
    | Absent -> [ "status", `String "absent" ]
    | Failed error -> [ "status", `String "failed"; "error", `String error ]
  in
  `Assoc ((("name", `String reading.name) :: status) @ [ "walk_ms", `Float reading.walk_ms ])
;;
