let dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "gate"
;;

let mode ~base_path = Filename.concat (dir ~base_path) "mode.json"

let external_mode ~base_path =
  Filename.concat (dir ~base_path) "external-mode.json"
;;
let pending ~base_path = Filename.concat (dir ~base_path) "pending.json"
let pending_log ~base_path = Filename.concat (dir ~base_path) "pending.log.jsonl"
let replay_results ~base_path =
  Filename.concat (dir ~base_path) "replay-results.json"
;;

let always_allowed ~base_path = Filename.concat (dir ~base_path) "always-allowed.json"
;;

let keeper_modes ~base_path = Filename.concat (dir ~base_path) "keeper-modes.json"
;;
