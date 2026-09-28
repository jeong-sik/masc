(* RFC play-link-for-the-shared-machine stage 1 (§2.2, §2.3, §5): the
   [Player] role an invite carries holds [CanPlayMachine] and nothing else,
   the five seat tools require exactly that permission, and [Worker] /
   [Admin] keep every right they had and gain the seat. *)

open Alcotest
module D = Masc_domain

let all_permissions =
  D.
    [ CanInit
    ; CanReset
    ; CanReadState
    ; CanAddTask
    ; CanClaimTask
    ; CanCompleteTask
    ; CanBroadcast
    ; CanVote
    ; CanAdmin
    ; CanPlayMachine
    ]

(* The tools an invited Player may call (§2.3). load, eject, restore and save
   change the game itself; peek reads what the screen hides; click is not
   needed for keyboard games. *)
let seat_tools =
  [ "masc_dos_screen"; "masc_dos_press"; "masc_dos_type"; "masc_dos_step"; "masc_dos_pass" ]

let test_player_holds_only_the_seat () =
  List.iter
    (fun p ->
      check bool
        ("player " ^ D.permission_to_string p)
        (p = D.CanPlayMachine)
        (D.has_permission D.Player p))
    all_permissions;
  check (list string) "player's permission list"
    [ "CanPlayMachine" ]
    (List.map D.permission_to_string (D.permissions_for_role D.Player))

let test_existing_roles_keep_their_rights_and_play () =
  List.iter
    (fun p ->
      check bool ("admin " ^ D.permission_to_string p) true (D.has_permission D.Admin p))
    all_permissions;
  List.iter
    (fun p ->
      let expected =
        match p with
        | D.CanInit | D.CanReset | D.CanAdmin -> false
        | D.CanReadState | D.CanAddTask | D.CanClaimTask | D.CanCompleteTask
        | D.CanBroadcast | D.CanVote | D.CanPlayMachine -> true
      in
      check bool ("worker " ^ D.permission_to_string p) expected (D.has_permission D.Worker p))
    all_permissions

let test_matrix_matches_the_list () =
  List.iter
    (fun role ->
      List.iter
        (fun p ->
          check bool
            (D.agent_role_to_string role ^ " " ^ D.permission_to_string p)
            (List.mem p (D.permissions_for_role role))
            (D.has_permission role p))
        all_permissions)
    D.all_agent_roles

let test_role_strings_round_trip () =
  check (list string) "role strings" [ "worker"; "admin"; "player" ] D.valid_agent_role_strings;
  List.iter
    (fun role ->
      check bool (D.agent_role_to_string role) true
        (D.agent_role_of_string (D.agent_role_to_string role) = Ok role);
      check bool
        (D.agent_role_to_string role ^ " through JSON")
        true
        (D.agent_role_of_yojson (D.agent_role_to_yojson role) = Ok role))
    D.all_agent_roles

let test_seat_tools_require_the_seat () =
  List.iter
    (fun tool_name ->
      match Tool_catalog.registered_metadata tool_name with
      | None -> failf "%s is not in the catalog" tool_name
      | Some meta ->
          check string (tool_name ^ " required permission") "CanPlayMachine"
            (D.permission_to_string meta.Tool_catalog.required_permission))
    seat_tools

let authorized role tool_name =
  match Auth.authorize_tool_for_role ~agent_name:"guest" ~role ~tool_name with
  | Ok () -> true
  | Error _ -> false

(* Every tool the catalog knows: a Player passes the five seat tools and is
   refused the rest, so no other tool can carry CanPlayMachine by accident. *)
let test_player_passes_only_the_seat_tools () =
  let known = Tool_catalog.known_names () in
  check bool "the catalog lists the seat tools" true
    (List.for_all (fun t -> List.mem t known) seat_tools);
  List.iter
    (fun tool_name ->
      check bool
        ("player " ^ tool_name)
        (List.mem tool_name seat_tools)
        (authorized D.Player tool_name))
    known

let test_keepers_and_operator_keep_the_seat_tools () =
  List.iter
    (fun tool_name ->
      check bool ("worker " ^ tool_name) true (authorized D.Worker tool_name);
      check bool ("admin " ^ tool_name) true (authorized D.Admin tool_name))
    seat_tools

let () =
  run "play-role-permissions"
    [ ( "roles"
      , [ test_case "a player holds only the seat" `Quick test_player_holds_only_the_seat
        ; test_case "worker and admin keep their rights and gain the seat" `Quick
            test_existing_roles_keep_their_rights_and_play
        ; test_case "has_permission matches permissions_for_role" `Quick
            test_matrix_matches_the_list
        ; test_case "role strings round-trip" `Quick test_role_strings_round_trip
        ] )
    ; ( "tools"
      , [ test_case "the five seat tools require CanPlayMachine" `Quick
            test_seat_tools_require_the_seat
        ; test_case "a player passes the seat tools and nothing else" `Quick
            test_player_passes_only_the_seat_tools
        ; test_case "worker and admin still pass the seat tools" `Quick
            test_keepers_and_operator_keep_the_seat_tools
        ] )
    ]
