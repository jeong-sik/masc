(** Every provider this ships, checked as a set.

    The per-provider tests next door pin one declaration in detail. This one
    exists because the hazards below only appear once there is more than one
    file: two providers that name the same environment entry, or the same
    refresh-token path, would each overwrite the other's tokens on a Keeper
    that attached both, and nothing would say so -- the second login would
    just quietly make the first service stop working.

    It also means a typo in a declaration is a red test rather than a
    provider that is missing from an operator's screen at runtime. *)

module Declarations = Keeper_oauth_declarations
module Provider = Keeper_oauth_provider
module Projection = Masc.Keeper_secret_projection

let providers () =
  List.map
    (function
      | Declarations.Declared provider -> provider
      | Declarations.Unreadable { id; problem } ->
        Alcotest.failf "config/identity/%s.toml does not read: %s" id problem)
    (Declarations.all ())

let temp_dir () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-identity-decl-%d" (Unix.getpid ()))
  in
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  path

(* [what] names the field, so a failure says which of the three collided. *)
let no_duplicates ~what values =
  let seen = Hashtbl.create 16 in
  List.iter
    (fun (id, value) ->
      match Hashtbl.find_opt seen value with
      | Some other ->
        Alcotest.failf
          "%s and %s both use %s %S; attaching both would have one overwrite \
           the other's tokens"
          other id what value
      | None -> Hashtbl.add seen value id)
    values

let test_every_shipped_declaration_reads () =
  match providers () with
  | [] -> Alcotest.fail "no provider is declared; the screen would be empty"
  | _ :: _ -> ()

(* The Identity tab prints a number beside each provider and acts on the
   digit pressed, so only single digits are reachable. The renderer's %d
   keeps counting past that: a tenth provider would be listed with a number
   that does nothing when pressed. Pinned here rather than in the screen's
   own tests because it is the size of this set that decides it. *)
let reachable_by_a_digit = 9

let test_the_set_stays_within_what_a_keypress_can_reach () =
  let count = List.length (providers ()) in
  if count > reachable_by_a_digit then
    Alcotest.failf
      "%d providers are declared but the Identity tab can only start the \
       first %d: the rest are listed with a number no keypress reaches. \
       Give the tab a moving selection instead of digits before declaring \
       another."
      count reachable_by_a_digit

let test_no_two_providers_share_an_access_token_entry () =
  no_duplicates ~what:"access_token_env"
    (List.map
       (fun (p : Provider.t) -> (p.Provider.id, p.Provider.access_token_env))
       (providers ()))

let test_no_two_providers_share_an_expiry_entry () =
  no_duplicates ~what:"expires_at_env"
    (List.map
       (fun (p : Provider.t) -> (p.Provider.id, p.Provider.expires_at_env))
       (providers ()))

let test_no_two_providers_share_a_refresh_token_file () =
  no_duplicates ~what:"refresh_token_file"
    (List.map
       (fun (p : Provider.t) -> (p.Provider.id, p.Provider.refresh_token_file))
       (providers ()))

let test_every_declaration_names_places_the_projection_accepts () =
  (* Asked of the projection rather than restated here: it owns what an
     absolute container path and an environment name may look like, and a
     copy of that rule in a test is a copy that goes stale. *)
  let base_path = temp_dir () in
  List.iter
    (fun (p : Provider.t) ->
      let keeper_name = "declaration-fixture" in
      (match
         Projection.set_file_entry ~base_path ~keeper_name
           ~scope:Projection.Keeper_secret
           ~container_path:p.Provider.refresh_token_file
           ~value:"a-refresh-token"
       with
       | Ok () -> ()
       | Error message ->
         Alcotest.failf "%s: refresh_token_file is not storable: %s"
           p.Provider.id message);
      let set name value =
        Projection.set_env_entry ~base_path ~keeper_name
          ~scope:Projection.Keeper_secret ~name ~value
      in
      (match set p.Provider.access_token_env "an-access-token" with
       | Ok () -> ()
       | Error message ->
         Alcotest.failf "%s: access_token_env is not storable: %s"
           p.Provider.id message);
      match set p.Provider.expires_at_env "1780000000" with
      | Ok () -> ()
      | Error message ->
        Alcotest.failf "%s: expires_at_env is not storable: %s" p.Provider.id
          message)
    (providers ())

let () =
  Alcotest.run "keeper_identity_declarations"
    [ ( "the set as shipped",
        [ Alcotest.test_case "every declaration reads" `Quick
            test_every_shipped_declaration_reads;
          Alcotest.test_case "the set stays reachable by a keypress" `Quick
            test_the_set_stays_within_what_a_keypress_can_reach;
          Alcotest.test_case "no two share an access token entry" `Quick
            test_no_two_providers_share_an_access_token_entry;
          Alcotest.test_case "no two share an expiry entry" `Quick
            test_no_two_providers_share_an_expiry_entry;
          Alcotest.test_case "no two share a refresh token file" `Quick
            test_no_two_providers_share_a_refresh_token_file;
          Alcotest.test_case "every declaration names storable places" `Quick
            test_every_declaration_names_places_the_projection_accepts;
        ] );
    ]
