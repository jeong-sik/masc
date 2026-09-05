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

type walk = Obj.t option -> measurement

type root =
  { root_name : string
  ; hold : walk -> measurement
  }

(* Newest first; readers reverse. A CAS loop keeps registration lock-free and
   correct from any domain. *)
let roots : root list Atomic.t = Atomic.make []

let register ~name hold =
  let rec attempt () =
    let current = Atomic.get roots in
    if List.exists (fun root -> String.equal root.root_name name) current
    then Error `Duplicate
    else if Atomic.compare_and_set roots current ({ root_name = name; hold } :: current)
    then Ok ()
    else attempt ()
  in
  attempt ()
;;

let registered () = List.rev_map (fun root -> root.root_name) (Atomic.get roots)

let bits_per_byte = 8
let words_to_bytes words = words * (Sys.word_size / bits_per_byte)
let milliseconds_per_second = 1000.0

let walk_value : walk = function
  | None -> Absent
  | Some value ->
    (match Obj.reachable_words value with
     | words -> Words words
     | exception exn -> Failed (Printexc.to_string exn))
;;

let measure_one ~now root =
  let started = now () in
  let measurement =
    match root.hold walk_value with
    | measurement -> measurement
    | exception exn -> Failed (Printexc.to_string exn)
  in
  { name = root.root_name
  ; measurement
  ; walk_ms = (now () -. started) *. milliseconds_per_second
  }
;;

let measure ~now () = List.rev_map (measure_one ~now) (Atomic.get roots)

let total_walk_ms readings =
  List.fold_left (fun acc reading -> acc +. reading.walk_ms) 0.0 readings
;;

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

module For_testing = struct
  let clear () = Atomic.set roots []
end
