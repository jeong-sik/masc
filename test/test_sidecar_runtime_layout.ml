(** Sidecar connectors keep their files under [.gate/runtime/<connector_id>/].

    The layout was spelled at nineteen sites, and the status resolver also
    carried a second one: [.masc/connectors/<id>/status.json] was appended to
    the candidate list and returned as the default when no file existed, so a
    fresh install was pointed at a path nothing writes. These pin the single
    layout and the absence of the second. *)

open Alcotest

module S = Channel_gate_sidecar_state
module P = Server_routes_http_sidecar_paths

let layout () =
  check string "runtime dir" ".gate/runtime/slack" (S.runtime_dir ~connector_id:"slack");
  check
    string
    "status"
    ".gate/runtime/discord/status.json"
    (S.default_status_path ~connector_id:"discord");
  check
    string
    "bindings"
    ".gate/runtime/imessage/bindings.json"
    (S.default_binding_store_path ~connector_id:"imessage");
  check
    string
    "audit"
    ".gate/runtime/telegram/binding_audit.jsonl"
    (S.default_binding_audit_path ~connector_id:"telegram")
;;

(* A caller holding only the directory must compose the same path a connector
   reads. *)
let files_sit_under_the_dir () =
  let id = "slack" in
  let dir = S.runtime_dir ~connector_id:id in
  List.iter
    (fun path -> check string ("under " ^ dir) dir (Filename.dirname path))
    [ S.default_status_path ~connector_id:id
    ; S.default_binding_store_path ~connector_id:id
    ; S.default_binding_audit_path ~connector_id:id
    ]
;;

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

(* The candidate list is what the status route serves; a compatibility path in
   it reaches operators as a real answer. *)
let no_second_layout () =
  let candidates = P.status_file_candidates ~base_path:"/tmp/masc-layout-probe" "discord" in
  List.iter
    (fun path ->
       check bool ("no connectors/ layout in " ^ path) false (contains path "connectors/"))
    candidates
;;

let () =
  run
    "sidecar_runtime_layout"
    [ ( "layout"
      , [ test_case "paths keep their spelling" `Quick layout
        ; test_case "files sit under the reported dir" `Quick files_sit_under_the_dir
        ; test_case "status candidates carry one layout" `Quick no_second_layout
        ] )
    ]
;;
