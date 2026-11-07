open Masc
module S = Lane_addon_superseded

let now_ms = 1_000L
let owner ?(revision = "r1") id = { S.id; source_path = "lanes/" ^ id ^ ".toml"; revision }

let binding ?(release = S.Released) ?(owner = Some (owner "lane")) ?(visibility = "shared")
    ?(persistence = S.Ephemeral) ?(minted_ms = 10L) instance_id =
  { S.identity = S.Minted { instance_id; minted_ms }; release; owner; visibility; persistence }

let plan ?(live = []) ?(faulted = []) bindings =
  S.plan ~now_ms ~live:(fun id -> List.mem id live)
    ~owner_faulted:(fun (o : S.owner) -> List.mem o.id faulted) bindings

let check_eligible expected (count : S.count) =
  Alcotest.(check (list string)) "eligible instances" expected count.eligible

let test_superseded_release_goes () =
  let count = plan [ binding "0001"; binding "0002" ] in
  check_eligible [ "0001" ] count;
  Alcotest.(check int) "the representative stays" 1 count.protected

let test_live_instance_stays () = check_eligible [] (plan ~live:[ "0001" ] [ binding "0001"; binding "0002" ])

let test_unreleased_instance_stays () =
  check_eligible [] (plan [ binding ~release:S.Not_released "0001"; binding "0002" ])

let test_ownerless_instance_stays () = check_eligible [] (plan [ binding ~owner:None "0001"; binding ~owner:None "0002" ])

let test_faulted_owner_stays () = check_eligible [] (plan ~faulted:[ "lane" ] [ binding "0001"; binding "0002" ])

let test_other_visibility_diverges () =
  let count = plan [ binding ~visibility:"operator" "0001"; binding ~visibility:"operator" "0002"; binding "0003" ] in
  check_eligible [] count;
  Alcotest.(check int) "both differ from the representative" 2 count.diverging_bindings;
  Alcotest.(check int) "one revision group" 1 count.diverging_groups

let test_unusable_time_never_represents () =
  let count =
    plan [ binding "0001"; binding "0002"; binding ~minted_ms:2_000L "0003";
      { (binding "0004") with S.identity = S.Unminted } ]
  in
  check_eligible [ "0001" ] count;
  Alcotest.(check int) "the representative, the future and the unminted binding stay" 3 count.protected

let test_other_revision_is_its_own_group () =
  check_eligible [] (plan [ binding "0001"; binding ~owner:(Some (owner ~revision:"r2" "lane")) "0002" ])

let persistent runtime = S.Persistent { package_id = "package"; runtime }

let test_persistent_same_runtime_goes () =
  check_eligible [ "0001" ]
    (plan [ binding ~persistence:(persistent "docker") "0001"; binding ~persistence:(persistent "docker") "0002" ])

let test_persistent_other_runtime_diverges () =
  let count =
    plan [ binding ~persistence:(persistent "podman") "0001"; binding ~persistence:(persistent "docker") "0002" ]
  in
  check_eligible [] count;
  Alcotest.(check int) "one persistent group" 1 count.diverging_groups

let test_persistent_representative_stays () =
  check_eligible []
    (plan [ binding ~persistence:(persistent "docker") "0001"; binding "0002" ])

let test_unreadable_package_stays () =
  check_eligible [] (plan [ binding ~persistence:S.Package_unreadable "0001"; binding "0002" ])

module Census = Lane_addon_superseded_census

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let write_file ~root relative size =
  let path = Filename.concat root relative in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel (String.make size 'x'))

(* An eligible and a kept instance, a directory with no binding, a symbolic
   link and a kept instance with no files at all. *)
let test_census_counts_each_instance_files () =
  let root = Filename.temp_dir "lane-superseded-census" "" in
  let observation id name = Filename.concat (Lane_addon_store.observation_dir id) name in
  write_file ~root (Lane_addon_store.binding_path "0001") 10;
  write_file ~root (observation "0001" "a.jsonl") 100;
  write_file ~root (observation "0001" "nested/b.jsonl") 50;
  write_file ~root (Lane_addon_store.action_path ~instance_id:"0001" ~request_id:"r") 5;
  write_file ~root (Lane_addon_store.binding_path "0002") 20;
  write_file ~root (observation "0002" "a.jsonl") 7;
  write_file ~root (observation "unbound" "a.jsonl") 1000;
  Unix.symlink
    (Filename.concat root (observation "unbound" "a.jsonl"))
    (Filename.concat root (observation "0001" "link.jsonl"));
  match Census.count ~root ~eligible:[ "0001" ] ~kept:[ "0002"; "0003" ] with
  | Error detail -> Alcotest.fail detail
  | Ok report ->
    Alcotest.(check (pair int int)) "instances" (1, 2) (report.eligible, report.kept);
    Alcotest.(check int64) "eligible binding, observations and actions" 165L report.eligible_bytes;
    Alcotest.(check int64) "kept instances, the one without files as zero" 27L report.kept_bytes;
    Alcotest.(check int64) "every observation file, the link not followed" 1157L
      report.observations_bytes

let () =
  Alcotest.run "lane addon superseded"
    [ ( "section 4.1",
        [ Alcotest.test_case "a superseded released binding goes" `Quick test_superseded_release_goes;
          Alcotest.test_case "a live instance stays" `Quick test_live_instance_stays;
          Alcotest.test_case "an unreleased instance stays" `Quick test_unreleased_instance_stays;
          Alcotest.test_case "an ownerless instance stays" `Quick test_ownerless_instance_stays;
          Alcotest.test_case "an owner with an unreadable record stays" `Quick test_faulted_owner_stays;
          Alcotest.test_case "another visibility diverges" `Quick test_other_visibility_diverges;
          Alcotest.test_case "a future or unminted id never represents" `Quick test_unusable_time_never_represents;
          Alcotest.test_case "another revision is its own group" `Quick test_other_revision_is_its_own_group;
          Alcotest.test_case "a persistent binding of the same runtime goes" `Quick test_persistent_same_runtime_goes;
          Alcotest.test_case "a persistent binding of another runtime diverges" `Quick
            test_persistent_other_runtime_diverges;
          Alcotest.test_case "the persistent representative stays" `Quick test_persistent_representative_stays;
          Alcotest.test_case "an unreadable package stays" `Quick test_unreadable_package_stays ] );
      ( "layer one bytes",
        [ Alcotest.test_case "each instance's files are counted once" `Quick
            test_census_counts_each_instance_files ] ) ]
