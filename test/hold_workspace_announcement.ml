(* Holds the owner lease of a workspace and announces one port for it, as a
   server boot does, so a test can put an HTTP stand-in on that port and have
   the kernel name this process as the server of the workspace. It prints
   [ready <pid>] once it holds both. A line [withdraw] on its stdin has it
   withdraw the announcement and keep the lease, as a server does once its
   listener closes, and it answers [withdrawn]. It holds the lease until its
   stdin closes. *)
type kind = Single_user | Account | Announces_nothing

let kind_of_arg = function
  | "single-user" -> Some Single_user
  | "account" -> Some Account
  | "none" -> Some Announces_nothing
  | _ -> None

let () =
  let base_path = ref None and port = ref None and kind = ref None in
  Arg.parse
    [ "--base-path", Arg.String (fun value -> base_path := Some value), "BASE_PATH";
      "--port", Arg.Int (fun value -> port := Some value), "PORT";
      "--kind", Arg.String (fun value -> kind := kind_of_arg value), "single-user|account|none" ]
    (fun extra -> raise (Arg.Bad ("unexpected argument " ^ extra)))
    "hold_workspace_announcement --base-path B --port P --kind single-user|account|none";
  match !base_path, !port, !kind with
  | None, _, _ | _, None, _ | _, _, None -> prerr_endline "--base-path, --port and --kind are required"; exit 2
  | Some base_path, Some port, Some kind ->
    let base_path = Unix.realpath base_path in
    (match
       Server_startup_takeover.acquire_owner_lease (Host_config.host ()).base_path_lease_root base_path
     with
     | Server_startup_takeover.Base_path_already_owned _ -> prerr_endline "the lease is held"; exit 1
     | Server_startup_takeover.Base_path_rejected rejection ->
       prerr_endline (Server_startup_takeover.base_path_lock_rejection_to_string rejection); exit 1
     | Server_startup_takeover.Base_path_acquired lease ->
       let withdrawal = ref None in
       let announced announce =
         match
           Server_startup_takeover.loopback_listener ~address:(Ipaddr.V4 Ipaddr.V4.localhost) ~port
         with
         | Error unreached -> Error (Server_startup_takeover.loopback_unreached_to_string unreached)
         | Ok listener ->
           (* The lock lasts until this process exits or is asked to withdraw
              it: no listener here would. *)
           announce lease listener ~withdraw_with:(fun withdraw -> withdrawal := Some withdraw)
           |> Result.map_error Server_startup_takeover.base_path_lock_rejection_to_string in
       let result =
         match kind with
         | Single_user -> announced Server_startup_takeover.announce_single_user_server
         | Account -> announced Server_startup_takeover.announce_account_server
         | Announces_nothing -> Ok () in
       (match result with
        | Error reason -> prerr_endline reason; exit 1
        | Ok () ->
          Printf.printf "ready %d\n%!" (Unix.getpid ());
          let rec serve () =
            match In_channel.input_line stdin with
            | None -> exit 0
            | Some "withdraw" ->
              (match !withdrawal with
               | Some withdraw ->
                 withdraw ();
                 withdrawal := None;
                 Printf.printf "withdrawn\n%!"
               | None -> Printf.printf "nothing to withdraw\n%!");
              serve ()
            | Some (_ : string) -> serve ()
          in
          serve ()))
