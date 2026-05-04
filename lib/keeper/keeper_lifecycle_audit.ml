(** Keeper_lifecycle_audit — in-memory ring buffer for keeper lifecycle events.

    Stores the last N lifecycle events per keeper so the dashboard
    (/api/v1/keepers/{name}/lifecycle) can surface a phase transition
    timeline without requiring the event bus to be replayed.

    Event storage is capped at [ring_capacity] (default 50) per keeper and
    survives process-lifetime (no disk persistence) — suitable for
    operator dashboards where recent history is more useful than full
    history.

    @since #12798 *)

let ring_capacity = 50

type lifecycle_event_entry = {
  ts : float;
  event_name : string;
  phase : string option;
  detail : string;
}

let ring : (string, lifecycle_event_entry array * int ref) Hashtbl.t =
  Hashtbl.create 16

let mu = Eio.Mutex.create ()

let with_lock f =
  Eio.Mutex.use_rw ~protect:true mu f

let record ~keeper_name ~event_name ~phase ~detail =
  with_lock (fun () ->
    let (arr, head) =
      match Hashtbl.find_opt ring keeper_name with
      | Some pair -> pair
      | None ->
          let arr = Array.make ring_capacity
            { ts = 0.0; event_name = ""; phase = None; detail = "" }
          in
          let pair = (arr, ref 0) in
          Hashtbl.replace ring keeper_name pair;
          pair
    in
    let entry = { ts = Unix.gettimeofday (); event_name; phase; detail } in
    arr.(!head mod ring_capacity) <- entry;
    head := !head + 1)

(** Return the most recent [limit] entries for [keeper_name], newest first.
    Returns [[]] if no events have been recorded. *)
let recent ~keeper_name ~limit =
  with_lock (fun () ->
    match Hashtbl.find_opt ring keeper_name with
    | None -> []
    | Some (arr, head) ->
        let count = min ring_capacity !head in
        let start = !head in
        let result = ref [] in
        for i = 0 to min (limit - 1) (count - 1) do
          (* Ring head points to the next write slot.  Walking backwards
             from (head - 1) gives newest → oldest order.  Adding
             [ring_capacity] before the modulo avoids negative values on
             the first wrap-around (when head < ring_capacity). *)
          let idx = (start - 1 - i + ring_capacity) mod ring_capacity in
          let e = arr.(idx) in
          if e.ts > 0.0 then result := e :: !result
        done;
        List.rev !result)

let recent_json ~keeper_name ~limit =
  let entries = recent ~keeper_name ~limit in
  `List (List.map (fun e ->
    `Assoc [
      ("ts", `Float e.ts);
      ("event", `String e.event_name);
      ("phase", match e.phase with None -> `Null | Some p -> `String p);
      ("detail", `String e.detail);
    ]) entries)
