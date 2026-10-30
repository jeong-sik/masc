(** The keeper store accessors open the folder each store has always used.

    The store list fixes every folder ([test_dated_jsonl_store]); this fixes
    which entry each accessor asks for. *)

open Alcotest
open Masc

let keeper = "store-location-probe"

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "keeper-store-locations-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () -> f (Workspace_core.default_config dir))
;;

let folder config dirname =
  Filename.concat (Filename.concat (Workspace.keepers_runtime_dir config) keeper) dirname
;;

let test_each_accessor_opens_its_folder () =
  with_workspace
  @@ fun config ->
  check
    string
    "metrics"
    (folder config "metrics")
    (Keeper_types_support.keeper_metrics_dir config keeper);
  check
    string
    "execution receipts"
    (folder config "execution-receipts")
    (Dated_jsonl.base_dir (Keeper_types_support.keeper_execution_receipt_store config keeper));
  check
    string
    "turn records"
    (folder config "turn-records")
    (Dated_jsonl.base_dir (Keeper_types_support.keeper_turn_record_store config keeper));
  check
    string
    "provider inputs"
    (folder config "provider-inputs")
    (Dated_jsonl.base_dir (Keeper_types_support.keeper_provider_input_store config keeper))
;;

let test_today_s_receipt_path_is_under_the_receipt_folder () =
  with_workspace
  @@ fun config ->
  let path =
    Keeper_runtime_manifest.execution_receipt_path_for_today config ~keeper_name:keeper
  in
  check
    string
    "day file sits two levels under the receipt folder"
    (folder config "execution-receipts")
    (Filename.dirname (Filename.dirname path))
;;

let () =
  run
    "keeper store locations"
    [ ( "accessors"
      , [ test_case "each accessor opens its folder" `Quick
            test_each_accessor_opens_its_folder
        ; test_case "today's receipt path is under the receipt folder" `Quick
            test_today_s_receipt_path_is_under_the_receipt_folder
        ] )
    ]
;;
