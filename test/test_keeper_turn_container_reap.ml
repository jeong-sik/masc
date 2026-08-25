(** A turn container has to be tellable from an earlier turn's.

    Turn-end teardown removes the container it created (#30604). When teardown
    does not run, nothing else takes it while the owning process is alive: the
    periodic sweep's [should_remove_container] wants the container stopped, its
    owner dead, or a ttl label the turn path never sets. Seven containers piled
    up that way in one server's lifetime (#30590).

    [reap_prior_turn_containers] closes that at the next turn's container
    creation, and it can only do so if two things hold, which is what this
    suite pins.

    1. Two factories in one process stamp different [masc.mcp.turn_id] values.
       They previously did not: both call sites left [?turn_id] at its default
       of 0, so every container carried 0 and the label separated nothing.

    2. The label filters actually narrow by owner pid and turn id, so
       "every turn container of mine" and "this turn's" are different listings.
       Docker label filters are equality-only, so the reap is their difference;
       if the filters did not narrow, the difference would be empty and the
       reap would silently do nothing. *)

open Alcotest

let meta_for name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let test_factories_get_distinct_turn_ids () =
  let config = Masc.Workspace.default_config "/tmp/masc-reap-test" in
  let meta = meta_for "reap-test" in
  let a = Masc.Keeper_sandbox_factory.create ~config ~meta () in
  let b = Masc.Keeper_sandbox_factory.create ~config ~meta () in
  let id_a = Masc.Keeper_sandbox_factory.turn_id a in
  let id_b = Masc.Keeper_sandbox_factory.turn_id b in
  check bool "a turn id is minted, not left at the old default of 0" true (id_a <> 0);
  check bool "two turns in one process never share a turn id" true (id_a <> id_b)
;;

let filter_args ?owner_pid ?turn_id () =
  Masc.Keeper_sandbox_runtime.docker_filter_args
    ~keeper_name:"reap-test"
    ~container_kind:Masc.Keeper_sandbox_runtime.turn_container_kind
    ?owner_pid
    ?turn_id
    ~base_path:"/tmp/masc-reap-test"
    ()
;;

let joined args = String.concat " " args

let test_filters_narrow_by_owner_and_turn () =
  let every_turn_of_mine = filter_args ~owner_pid:4242 () in
  let this_turn = filter_args ~owner_pid:4242 ~turn_id:7 () in
  let contains ~needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
    n = 0 || loop 0
  in
  check
    bool
    "the owner pid narrows the listing"
    true
    (contains ~needle:"label=masc.mcp.owner_pid=4242" (joined every_turn_of_mine));
  check
    bool
    "without a turn id the listing is not narrowed by one"
    false
    (contains ~needle:"masc.mcp.turn_id" (joined every_turn_of_mine));
  check
    bool
    "the turn id narrows the listing"
    true
    (contains ~needle:"label=masc.mcp.turn_id=7" (joined this_turn));
  (* The reap is the difference of these two listings. Equal argument lists
     would make it empty, and the reap would remove nothing while reporting
     success. *)
  check
    bool
    "the two listings differ, so their difference can be non-empty"
    false
    (joined every_turn_of_mine = joined this_turn)
;;

let () =
  run
    "keeper turn container reap"
    [ ( "turn identity"
      , [ test_case "factories get distinct turn ids" `Quick test_factories_get_distinct_turn_ids
        ; test_case
            "filters narrow by owner and turn"
            `Quick
            test_filters_narrow_by_owner_and_turn
        ] )
    ]
;;
