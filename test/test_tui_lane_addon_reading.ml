(* The Lanes surface distinguishes declarations from active workers. A saved
   TOML with an unavailable image must never appear as an installed worker. *)

open Alcotest
module UI = Masc_tui_lane_addons

let configuration : UI.configuration =
  { directory = "/addons"; complete = true; declarations = [] }

let declaration : UI.declaration =
  { source_path = "/addons/one.toml"
  ; installation_id = None
  ; desired = Some "r1"
  ; applied = None
  ; instance_id = None
  ; issues = []
  ; enabled = Some true
  ; application = None
  ; origin = UI.Parsed_declaration
  }

let snapshot_of declarations : UI.snapshot =
  { instances = []
  ; output = { Masc.Lane_addon_types.rows = []; coverage = [] }
  ; complete = Some true
  ; configuration = Some { configuration with declarations }
  }

let view_of declarations = { UI.initial with snapshot = Some (snapshot_of declarations) }

let test_an_untouched_view_has_not_read () =
  check bool "nothing asked, nothing answered" true (UI.installation_reading UI.initial = UI.Not_read)

(* A snapshot without a configuration is the Add-on stream answering about
   instances and output while the installation directory is still unread. *)
let test_a_snapshot_without_a_configuration_has_not_read_either () =
  let snapshot = { (snapshot_of []) with configuration = None } in
  check bool "no configuration is no reading" true
    (UI.installation_reading { UI.initial with snapshot = Some snapshot } = UI.Not_read)

let test_a_read_that_found_none_says_so () =
  check bool "empty is its own answer" true
    (UI.installation_reading (view_of []) = UI.Observed {
       declared=0; active=0; failed_workers=0; configuration_issues=0;
       complete=true; freshness=UI.Current })

let test_unapplied_declarations_are_not_active_workers () =
  let broken = { declaration with issues = ["Docker image missing"] } in
  check bool "two broken declarations, no active worker" true
    (UI.installation_reading (view_of [ broken; broken ]) = UI.Observed {
       declared=2; active=0; failed_workers=0; configuration_issues=2;
       complete=true; freshness=UI.Current });
  let partial = { (snapshot_of [broken]) with
    configuration=Some { configuration with complete=false; declarations=[broken] } } in
  check bool "partial inventory stays partial" true
    (UI.installation_reading { UI.initial with snapshot=Some partial } = UI.Observed {
       declared=1; active=0; failed_workers=0; configuration_issues=1;
       complete=false; freshness=UI.Current });
  let unreadable = { broken with desired=None; installation_id=None;
      issues=["Invalid TOML"; "Cannot resolve package"]; enabled=None; origin=UI.Issue_only } in
  check bool "an issue-only path is not a parsed declaration" true
    (UI.installation_reading (view_of [unreadable]) = UI.Observed {
       declared=0; active=0; failed_workers=0; configuration_issues=2;
       complete=true; freshness=UI.Current });
  check bool "failed reread preserves the old count with stale provenance" true
    (UI.installation_reading { (view_of [broken]) with snapshot_read_error=Some "HTTP 503" }
     = UI.Observed { declared=1; active=0; failed_workers=0;
                     configuration_issues=1; complete=true;
                     freshness=UI.Stale "HTTP 503" })

let test_directory_issue_is_not_a_declaration () =
  let json = Yojson.Safe.from_string
    {|{"instances":[],"rows":[],"coverage":[],"configuration":{"directory":"/addons","complete":false,"declarations":[],"issues":[{"source_path":"/addons","id":null,"message":"directory unreadable"}]}}|} in
  match UI.decode json with
  | Error detail -> fail ("directory issue fixture did not decode: " ^ detail)
  | Ok snapshot ->
    check bool "directory problem without a parsed TOML is zero declarations" true
      (UI.installation_reading { UI.initial with snapshot=Some snapshot }
       = UI.Observed { declared=0; active=0; failed_workers=0;
                       configuration_issues=1; complete=false;
                       freshness=UI.Current })

let () =
  run "tui lane addon reading"
    [ ( "installation reading"
      , [ test_case "an untouched view has not read" `Quick
            test_an_untouched_view_has_not_read
        ; test_case "a snapshot without a configuration has not read either" `Quick
            test_a_snapshot_without_a_configuration_has_not_read_either
        ; test_case "a read that found none says so" `Quick
            test_a_read_that_found_none_says_so
        ; test_case "unapplied declarations are not active workers" `Quick
            test_unapplied_declarations_are_not_active_workers
        ; test_case "directory issue is not a declaration" `Quick
            test_directory_issue_is_not_a_declaration
        ;] )
    ]
