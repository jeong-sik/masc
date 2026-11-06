(** The browser worker refuses a malformed backend configuration before it
    starts anything. *)
module Live = Masc.Browser_addon_live_bidi
let check label expected actual = Alcotest.(check bool) label expected actual
let refused label result = check label true (Result.is_error result)
let admitted label result = check label true (Result.is_ok result)
let decoders () =
  let id=`Assoc ["device",`Int 1;"inode",`Int 2] in
  let firefox ~port ~profile ~root=`Assoc ["claim_directory",`String "/c";"firefox",`String "/f";"gate",id;
    "guardian",`String "/g";"launcher",`String "/l";"lease",id;"port",`Int port;"profile",`String profile;
    "root",root;"slot",id] in
  admitted "a Firefox configuration decodes" (Live.configuration_of_json (firefox ~port:9222 ~profile:"/p" ~root:id));
  refused "a Firefox port of 0 is refused" (Live.configuration_of_json (firefox ~port:0 ~profile:"/p" ~root:id));
  refused "a relative Firefox profile is refused" (Live.configuration_of_json (firefox ~port:9222 ~profile:"p" ~root:id));
  refused "a Firefox identity without an inode is refused"
    (Live.configuration_of_json (firefox ~port:9222 ~profile:"/p" ~root:(`Assoc ["device",`Int 1])));
  refused "a Firefox identity with a string inode is refused"
    (Live.configuration_of_json (firefox ~port:9222 ~profile:"/p" ~root:(`Assoc ["device",`Int 1;"inode",`String "2"])));
  refused "a Firefox key set without slot is refused" (Live.configuration_of_json (`Assoc ["firefox",`String "/f"]))
let () =
  Alcotest.run "browser add-on decoders"
    ["decoders",[Alcotest.test_case "configuration decoders refuse wrong keys and fields" `Quick decoders]]
