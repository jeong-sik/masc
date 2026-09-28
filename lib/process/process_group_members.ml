type state =
  | Zombie
  | Exiting
  | Live

type member = { pid : int; parent : int; state : state }

external snapshot : int -> (int * int * bool * bool) array option =
  "masc_process_group_members"

let member_of_row (pid, parent, zombie, exiting) =
  (* A zombie carries the exiting flag as well, so it is read first. *)
  let state = if zombie then Zombie else if exiting then Exiting else Live in
  { pid; parent; state }

let no_live_member ~leader ~owner members =
  List.exists (fun member -> member.pid = leader && member.parent = owner) members
  && List.for_all
       (fun member ->
         match member.state with
         | Zombie | Exiting -> true
         | Live -> false)
       members

let group_has_no_live_member pgid =
  match snapshot pgid with
  | None -> false
  | Some rows ->
    no_live_member ~leader:pgid ~owner:(Unix.getpid ())
      (Array.to_list (Array.map member_of_row rows))
