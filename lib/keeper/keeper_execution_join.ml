(* See keeper_execution_join.mli for the happens-before argument that
   makes this table deterministic rather than a time-window heuristic. *)

let table : (string, string) Hashtbl.t = Hashtbl.create 64
let lock = Mutex.create ()

let record ~tool_use_id ~execution_id =
  if tool_use_id <> "" then begin
    Mutex.lock lock;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock)
      (fun () -> Hashtbl.replace table tool_use_id execution_id)
  end

let take ~tool_use_id =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
      match Hashtbl.find_opt table tool_use_id with
      | Some execution_id ->
        Hashtbl.remove table tool_use_id;
        Some execution_id
      | None -> None)

module For_testing = struct
  let size () =
    Mutex.lock lock;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock)
      (fun () -> Hashtbl.length table)

  let clear () =
    Mutex.lock lock;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock)
      (fun () -> Hashtbl.reset table)
end
