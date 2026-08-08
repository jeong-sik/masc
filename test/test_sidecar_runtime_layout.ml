(** Sidecar connectors keep their files under [.gate/runtime/<connector_id>/].

    Four channel modules and six server call sites each spelled that layout,
    so a relocation had to be applied in eighteen places or the connector and
    the route that reports its paths would disagree. These pin the strings the
    single owner now produces. *)

open Alcotest

module S = Channel_gate_sidecar_state

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

(* The three file paths must sit inside the directory the same owner reports,
   or a caller holding only the directory composes a different path. *)
let files_sit_under_the_dir () =
  let id = "slack" in
  let dir = S.runtime_dir ~connector_id:id in
  List.iter
    (fun path ->
       check
         string
         ("under " ^ dir)
         dir
         (Filename.dirname path))
    [ S.default_status_path ~connector_id:id
    ; S.default_binding_store_path ~connector_id:id
    ; S.default_binding_audit_path ~connector_id:id
    ]
;;

let () =
  run
    "sidecar_runtime_layout"
    [ ( "layout"
      , [ test_case "paths keep their pre-refactor spelling" `Quick layout
        ; test_case "files sit under the reported dir" `Quick files_sit_under_the_dir
        ] )
    ]
;;
