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
    (* NDT-OK: the owner is this process by definition -- the check asks
       whether the leader is still our own unreaped child. *)
    no_live_member ~leader:pgid ~owner:(Unix.getpid ())
      (Array.to_list (Array.map member_of_row rows))

let live_member_left pgid =
  Option.map
    (fun rows ->
      Array.exists (fun row -> match (member_of_row row).state with Live -> true | Zombie | Exiting -> false) rows)
    (snapshot pgid)

(* Linux has no kernel member snapshot here, but /proc names every process
   with its state and group. A group that kill(2) still reaches may hold only
   zombies, which stay until their parent reaps them; they are not processes
   left running. *)
let proc_member_row name =
  match int_of_string_opt name with
  | None -> None
  | Some pid ->
    (match In_channel.with_open_bin (Filename.concat "/proc" (Filename.concat name "stat")) In_channel.input_all with
     | exception Sys_error _ -> None
     | stat ->
       (* "pid (comm) S ppid pgrp ...": comm may hold spaces and ')', so the
          fields are read after the last ')'. *)
       (match String.rindex_opt stat ')' with
        | None -> None
        | Some close ->
          let rest = String.sub stat (close + 1) (String.length stat - close - 1) in
          (match String.split_on_char ' ' (String.trim rest) with
           | state :: ppid :: pgrp :: _ ->
             (match int_of_string_opt ppid, int_of_string_opt pgrp with
              | Some parent, Some group -> Some (pid, parent, group, state)
              | _ -> None)
           | _ -> None)))

let proc_live_member_left pgid =
  if not (Sys.file_exists "/proc/self/stat") then None
  else
    match Sys.readdir "/proc" with
    | exception Sys_error _ -> None
    | names ->
      Some
        (Array.exists
           (fun name ->
             match proc_member_row name with
             | Some (_, _, group, state) when group = pgid -> not (state = "Z" || state = "X")
             | Some _ | None -> false)
           names)
