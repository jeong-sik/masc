(* The argv is built before anything can run it, so these tests are what say
   it is right. Measured against container CLI 1.3.0 on 2026-08-28: every
   flag asserted here was accepted by a live `container run`, and the two in
   [unsupported_docker_flags] were rejected with "Unknown option". *)

module M = Masc.Keeper_sandbox_microvm
module Profile = Keeper_types_profile_sandbox

let argv ?(network = Profile.Network_none) () =
  M.run_argv
    ~container_name:"masc-keeper-turn-probe"
    ~container_root:"/home/keeper/playground/probe"
    ~container_cwd:"/home/keeper/playground/probe"
    ~host_root:"/base/.masc/playground/microvm/probe"
    ~image:"masc-keeper-sandbox:local"
    ~network_args:(M.network_args ~dns:(Some "1.1.1.1") network)
    ~uid:501
    ~gid:20
    ~env_args:[ "--env"; "MASC_PROBE=1" ]
    ~memory:"2g"

let contains needle haystack = List.exists (String.equal needle) haystack

let adjacent ~flag ~value argv =
  let rec go = function
    | a :: b :: rest -> (String.equal a flag && String.equal b value) || go (b :: rest)
    | _ -> false
  in
  go argv

(* container errors on an unknown option instead of ignoring it, so copying
   Docker's argv wholesale would fail every call rather than quietly weaken
   the sandbox. This is the assertion that catches that copy. *)
let test_omits_flags_container_rejects () =
  let a = argv () in
  List.iter
    (fun flag ->
       if contains flag a
       then
         Alcotest.failf
           "run_argv passes %s, which container run rejects with \"Unknown \
            option\" -- every call would fail"
           flag)
    M.unsupported_docker_flags

(* The hardening that does carry over. Dropping any of these silently is the
   failure this pins: the profile is chosen for isolation, so an argv that
   forgets --read-only still runs, and nothing else would notice. *)
let test_keeps_the_hardening_container_accepts () =
  let a = argv () in
  Alcotest.(check bool) "drops capabilities" true (adjacent ~flag:"--cap-drop" ~value:"ALL" a);
  Alcotest.(check bool) "read-only rootfs" true (contains "--read-only" a);
  Alcotest.(check bool) "removes the container" true (contains "--rm" a);
  Alcotest.(check bool) "runs as the caller" true (adjacent ~flag:"--user" ~value:"501:20" a);
  Alcotest.(check bool) "caps memory" true (adjacent ~flag:"--memory" ~value:"2g" a)

let test_mounts_the_keeper_root_at_the_guest_root () =
  let a = argv () in
  Alcotest.(check bool)
    "mounts host root at container root"
    true
    (adjacent
       ~flag:"--volume"
       ~value:"/base/.masc/playground/microvm/probe:/home/keeper/playground/probe"
       a);
  Alcotest.(check bool)
    "starts in the guest cwd"
    true
    (adjacent ~flag:"--workdir" ~value:"/home/keeper/playground/probe" a)

(* Network_none has to reach the command as an argument. An empty list here
   would leave the guest on the default network while the profile reported
   "none" -- the shape of #31178, one layer down. *)
let test_closed_network_is_spelled_on_the_command () =
  Alcotest.(check (list string))
    "none closes the network"
    [ "--network"; "none" ]
    (M.network_args ~dns:(Some "1.1.1.1") Profile.Network_none);
  (* inherit uses container's NAT, which routes outside. What it needs is a
     nameserver: the guest's resolver points at the gateway and the gateway
     refuses DNS from inside, so an inherit guest with no --dns routes fine
     and resolves nothing -- which reads as a dead network and is what made
     an earlier version refuse inherit on a claim that was wrong. *)
  Alcotest.(check (list string))
    "inherit carries the nameserver"
    [ "--dns"; "1.1.1.1" ]
    (M.network_args ~dns:(Some "1.1.1.1") Profile.Network_inherit);
  Alcotest.(check (list string))
    "an empty nameserver passes no --dns"
    []
    (M.network_args ~dns:(Some "") Profile.Network_inherit);
  Alcotest.(check bool)
    "the closed network reaches run_argv"
    true
    (adjacent ~flag:"--network" ~value:"none" (argv ~network:Profile.Network_none ()));
  Alcotest.(check bool)
    "an inherit guest is given a resolver"
    true
    (adjacent ~flag:"--dns" ~value:"1.1.1.1" (argv ~network:Profile.Network_inherit ()))

let test_image_and_shell_come_last () =
  let a = argv () in
  match List.rev a with
  | "-s" :: "-l" :: "bash" :: image :: _ ->
    Alcotest.(check string) "image precedes the shell" "masc-keeper-sandbox:local" image
  | rest ->
    Alcotest.failf
      "argv must end with <image> bash -l -s, got: %s"
      (String.concat " " (List.rev rest))

let () =
  Alcotest.run
    "keeper_sandbox_microvm"
    [ ( "argv"
      , [ Alcotest.test_case "omits flags container rejects" `Quick
            test_omits_flags_container_rejects
        ; Alcotest.test_case "keeps the hardening container accepts" `Quick
            test_keeps_the_hardening_container_accepts
        ; Alcotest.test_case "mounts the keeper root at the guest root" `Quick
            test_mounts_the_keeper_root_at_the_guest_root
        ; Alcotest.test_case "closed network is spelled on the command" `Quick
            test_closed_network_is_spelled_on_the_command
        ; Alcotest.test_case "image and shell come last" `Quick
            test_image_and_shell_come_last
        ] )
    ]
