(* Slack_lane — the in-server ring buffer of collected Slack messages.

   docs/design/slack-lane.md, task-1418. The poll fiber
   ({!Server_slack_poll_lane}) appends what conversations.history returned
   after filtering; the TUI tab and the keeper reader tool read the same
   state. Memory only — the durable truth is Slack itself plus the poll
   cursor file, so a server restart refills forward, never backward.

   Mirrors {!Browser_lane}'s shape: one mutex, one table, no sockets.
   Storage is a plain list per channel, oldest first; Slack ts are
   fixed-point strings where lexicographic order matches chronological
   order, so ordering comparisons stay on strings. *)

let default_capacity_per_channel = 500

type lane_message = {
  channel_id : string;
  ts : string;
  user_id : string;
  text : string;
  (* Wall-clock receive time is a debugging aid, not ordering truth. *)
  received_unix : float;
}

let table : (string, lane_message list ref) Hashtbl.t = Hashtbl.create 8
let mutex = Eio.Mutex.create ()

(* [protect:false] — the critical section is list/Hashtbl work with no
   cancellation checkpoint, so blocking cancellation here would only add the
   known use_rw trap. *)
let with_lock f = Eio.Mutex.use_rw ~protect:false mutex f

let capacity_trim ~capacity (msgs : lane_message list) : lane_message list =
  let rec drop_oldest n = function
    | rest when n <= 0 -> rest
    | [] -> []
    | _ :: rest -> drop_oldest (n - 1) rest
  in
  let overflow = List.length msgs - capacity in
  if overflow > 0 then drop_oldest overflow msgs else msgs
;;

(* Oldest first. A duplicate ts — a re-read window after a failed cursor
   write — is dropped, which is the lane's whole dedupe contract. *)
let push ~channel_id (msg : lane_message) ~capacity =
  with_lock (fun () ->
      let cell =
        match Hashtbl.find_opt table channel_id with
        | Some cell -> cell
        | None ->
          let cell = ref [] in
          Hashtbl.replace table channel_id cell;
          cell
      in
      let duplicate =
        List.exists (fun existing -> String.equal existing.ts msg.ts) !cell
      in
      if not duplicate then (
        cell := !cell @ [ msg ];
        cell := capacity_trim ~capacity !cell)
      ;
      ())
;;

let push_many ~channel_id (msgs : lane_message list) ~capacity =
  List.iter (fun msg -> push ~channel_id msg ~capacity) msgs
;;

(* Newest first — a viewer reads the tail of the conversation. *)
let recent ~channel_id ~limit =
  with_lock (fun () ->
      match Hashtbl.find_opt table channel_id with
      | None -> []
      | Some cell ->
        let rec take n = function
          | _ when n <= 0 -> []
          | [] -> []
          | x :: rest -> x :: take (n - 1) rest
        in
        take limit (List.rev !cell))
;;

let channels () =
  with_lock (fun () ->
      Hashtbl.fold
        (fun channel_id cell acc -> (channel_id, List.length !cell) :: acc)
        table []
      |> List.sort compare)
;;

let clear () = with_lock (fun () -> Hashtbl.reset table)
;;
