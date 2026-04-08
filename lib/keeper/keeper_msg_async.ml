(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Entries auto-expire after [max_age_sec] to prevent memory leaks. *)

open Keeper_types

type request_status =
  | Queued
  | Running
  | Done of { ok : bool; body : string }

type entry = {
  request_id : string;
  keeper_name : string;
  status : request_status;
  submitted_at : float;
  completed_at : float option;
}

let mu = Mutex.create ()
let pending : (string, entry) Hashtbl.t = Hashtbl.create 16
let counter = Atomic.make 0

let max_age_sec = 3600.0

let generate_request_id ~keeper_name =
  let n = Atomic.fetch_and_add counter 1 in
  Printf.sprintf "kmsg_%s_%d_%d" keeper_name n
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let with_lock f =
  Mutex.lock mu;
  Fun.protect f ~finally:(fun () -> Mutex.unlock mu)

let gc_stale () =
  let now = Unix.gettimeofday () in
  let stale = with_lock (fun () ->
    Hashtbl.fold (fun id entry acc ->
      if now -. entry.submitted_at > max_age_sec then id :: acc
      else acc
    ) pending []
  ) in
  List.iter (fun id ->
    with_lock (fun () -> Hashtbl.remove pending id)
  ) stale

let set_status request_id status =
  with_lock (fun () ->
    match Hashtbl.find_opt pending request_id with
    | Some entry ->
      let completed_at = match status with
        | Done _ -> Some (Unix.gettimeofday ())
        | _ -> None
      in
      Hashtbl.replace pending request_id { entry with status; completed_at }
    | None -> ()
  )

(** Submit a keeper_msg turn for async execution.
    Forks a background fiber on [sw], returns the request_id immediately. *)
let submit ~sw ~(f : unit -> tool_result) ~keeper_name : string =
  gc_stale ();
  let request_id = generate_request_id ~keeper_name in
  let entry = {
    request_id;
    keeper_name;
    status = Queued;
    submitted_at = Unix.gettimeofday ();
    completed_at = None;
  } in
  with_lock (fun () -> Hashtbl.replace pending request_id entry);
  Eio.Fiber.fork_daemon ~sw (fun () ->
    set_status request_id Running;
    let result =
      try
        let (ok, body) = f () in
        Done { ok; body }
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Done { ok = false; body = Printf.sprintf "keeper_msg failed: %s" (Printexc.to_string exn) }
    in
    set_status request_id result;
    `Stop_daemon
  );
  request_id

(** Poll for the result of an async keeper_msg request. *)
let poll request_id : entry option =
  with_lock (fun () -> Hashtbl.find_opt pending request_id)

(** List all pending/running requests for a keeper. *)
let list_for_keeper ~keeper_name : entry list =
  with_lock (fun () ->
    Hashtbl.fold (fun _id entry acc ->
      if entry.keeper_name = keeper_name then entry :: acc
      else acc
    ) pending []
  )
  |> List.sort (fun a b -> compare b.submitted_at a.submitted_at)

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Done { ok = true; _ } -> "done"
  | Done { ok = false; _ } -> "error"

let entry_to_json (e : entry) : Yojson.Safe.t =
  let fields = [
    ("request_id", `String e.request_id);
    ("keeper_name", `String e.keeper_name);
    ("status", `String (status_to_string e.status));
    ("submitted_at", `Float e.submitted_at);
  ] in
  let fields = match e.completed_at with
    | Some t -> fields @ [("completed_at", `Float t)]
    | None ->
      let elapsed = Unix.gettimeofday () -. e.submitted_at in
      fields @ [("elapsed_sec", `Float elapsed)]
  in
  let fields = match e.status with
    | Done { ok; body } ->
      fields @ [
        ("ok", `Bool ok);
        ("result", (try Yojson.Safe.from_string body with Eio.Cancel.Cancelled _ as e -> raise e | _ -> `String body));
      ]
    | _ -> fields
  in
  `Assoc fields
