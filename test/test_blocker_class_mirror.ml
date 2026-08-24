(* The dashboard keeps its own list of blocker classes, and the server's
   `blocker_class_to_string` is what actually reaches it. Nothing compared the
   two, so eleven classes the server emits were absent from the frontend union
   and `asKeeperRuntimeBlockerClass` answered null for each — the value arrived
   and was dropped, with no error anywhere.

   Read both lists and require the server's to be covered. The frontend may
   hold extra entries: the status bridge and the runtime trust pipeline emit
   dashboard-only classes that never pass through `keeper_meta_contract`. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let repo_root =
  (* The test runs from the dune build context; walk up to the tree that has
     both sides of the mirror in it. *)
  let rec up dir depth =
    if depth > 8 then failwith "repo root not found from the test's cwd"
    else if Sys.file_exists (Filename.concat dir "dune-project") then dir
    else up (Filename.concat dir Filename.parent_dir_name) (depth + 1)
  in
  up (Sys.getcwd ()) 0
;;

let matches re s =
  let rec collect pos acc =
    match Re.exec_opt ~pos re s with
    | None -> List.rev acc
    | Some g ->
      let value = Re.Group.get g 1 in
      let _, stop = Re.Group.offset g 0 in
      collect stop (value :: acc)
  in
  collect 0 []
;;

let server_classes () =
  let path =
    Filename.concat repo_root "lib/keeper/keeper_meta_contract.ml"
  in
  let source = read_file path in
  let re = Re.Pcre.re {|-> "([a-z_]+)"|} |> Re.compile in
  let body =
    match
      Re.exec_opt
        (Re.Pcre.re {|let blocker_class_to_string = function([\s\S]*?);;|}
         |> Re.compile)
        source
    with
    | Some g -> Re.Group.get g 1
    | None -> failwith "blocker_class_to_string not found"
  in
  matches re body |> List.sort_uniq String.compare
;;

let dashboard_classes () =
  let path = Filename.concat repo_root "dashboard/src/types/core.ts" in
  let source = read_file path in
  let body =
    match
      Re.exec_opt
        (Re.Pcre.re {|KEEPER_RUNTIME_BLOCKER_CLASSES = \[([\s\S]*?)\] as const|}
         |> Re.compile)
        source
    with
    | Some g -> Re.Group.get g 1
    | None -> failwith "KEEPER_RUNTIME_BLOCKER_CLASSES not found"
  in
  matches (Re.Pcre.re {|'([a-z_]+)'|} |> Re.compile) body
  |> List.sort_uniq String.compare
;;

let test_server_classes_are_all_known_to_the_dashboard () =
  let server = server_classes () in
  let dashboard = dashboard_classes () in
  Alcotest.(check bool) "server emits classes" true (List.length server > 0);
  Alcotest.(check bool) "dashboard declares classes" true (List.length dashboard > 0);
  let missing = List.filter (fun c -> not (List.mem c dashboard)) server in
  Alcotest.(check (list string))
    "every class the server emits is declared in the dashboard union"
    []
    missing
;;

let () =
  Alcotest.run
    "Blocker_class_mirror"
    [ ( "coverage"
      , [ Alcotest.test_case
            "server classes are known to the dashboard"
            `Quick
            test_server_classes_are_all_known_to_the_dashboard
        ] )
    ]
;;
