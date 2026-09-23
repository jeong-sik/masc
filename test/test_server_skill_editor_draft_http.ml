(** The operator editor publishes a Keeper's validated draft by reference.

    A Keeper exports SKILL.md bytes and checks them with
    [keeper_skill_validate]. The operator passes the same
    [{artifact, package_id}] pair to [/api/v1/skills/editor/create] or
    [/save]; the server reads the exported bytes itself, validates them with
    the editor's own path and publishes them. These cases go through the real
    router, token authorization and the runtime config that the route reloads.
    The exported bytes are synthetic; they stand in for a Keeper's export and
    use the export producer's durable blob store and reference shape. *)

open Alcotest
open Masc

module Http = Http_server_eio
module Service = Skill_catalog_snapshot_service
module U = Yojson.Safe.Util

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let require_ok error = function Ok value -> value | Error value -> fail (error value)

let write_file path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel text)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let skill_config =
  "[skills]\n[[skills.sources]]\nid = \"workspace\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-write\"\n"
;;

let instruction ~name ~description =
  Printf.sprintf "---\nname: %s\ndescription: %s\n---\nRead keeper_lane_status before reporting.\n"
    name description
;;

type fixture =
  { base_path : string
  ; config : Workspace.config
  ; router : Http.Router.t
  ; admin : string
  ; worker : string
  }

let with_fixture f =
  let base_path = Filename.temp_dir "skill-editor-draft-http" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      restore_env "MASC_CONFIG_DIR" previous_config_dir;
      Config_dir_resolver.reset ();
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      (* Every store below is the one the routes resolve from this state. *)
      let base_path = config.Workspace.base_path in
      (* The routes reload the runtime config after a write; point that
         reload at a config that declares the writable source. *)
      let config_dir = Filename.concat base_path "config" in
      Unix.mkdir config_dir 0o700;
      write_file (Filename.concat config_dir "runtime.toml") skill_config;
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      Unix.mkdir (Filename.concat base_path "skills") 0o700;
      let workspace =
        Service.workspace_of_base_path ~base_path |> require_ok (fun _ -> "workspace")
      in
      Fun.protect ~finally:(fun () -> Service.retire ~workspace) (fun () ->
        (match Service.refresh ~workspace ~user_home:None
                 ~read_config:(fun () -> Service.Config_text skill_config) with
         | Service.Published _ | Unchanged _ -> ()
         | Workspace_retired -> fail "fixture snapshot retired");
        ignore (Workspace.init config ~agent_name:None);
        Server_auth.For_testing.restore_server_state (Some state);
        Auth.save_auth_config base_path
          { Masc_domain.default_auth_config with enabled = true; require_token = true };
        let token agent_name role =
          fst (require_ok Masc_domain.masc_error_to_string
                 (Auth.create_token base_path ~agent_name ~role)) in
        let router = Server_routes_http_routes_dashboard.add_routes ~sw
            ~clock:(Eio.Stdenv.clock env) (Http.Router.create ()) in
        f { base_path; config; router
          ; admin = token "skill-operator" Masc_domain.Admin
          ; worker = token "skill-worker" Masc_domain.Worker }))
;;

let http fixture ?token ~path body =
  let body = Yojson.Safe.to_string body in
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http.Router.dispatch fixture.router (Httpun.Reqd.request reqd) reqd) in
  let authorization = match token with
    | None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let raw_request = Printf.sprintf
    "POST %s HTTP/1.1\r\nHost: x\r\n%sContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
    path authorization (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  let rec body_offset index =
    if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index + 4 else body_offset (index + 1) in
  let offset = body_offset 0 in
  status, Yojson.Safe.from_string (String.sub raw offset (String.length raw - offset))
;;

(* Export the bytes the way [keeper_artifact_transfer] does, then run the
   Keeper tool and hand back the exact pair it verified. *)
let validated_draft fixture ~package_id source_text =
  let blob = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:source_text ~mime:"application/octet-stream" in
  let artifact =
    Keeper_peer_artifact_ref.make ~blob ~filename:"SKILL.md" ~purpose:"Propose a Skill"
    |> require_ok Fun.id |> Keeper_peer_artifact_ref.to_json in
  let result = Keeper_skill_validate.handle ~config:fixture.config
      ~args:(`Assoc [ "artifact", artifact; "package_id", `String package_id ]) in
  let data = match result.Keeper_tool_execution.data with Some data -> data | None -> fail "missing tool result" in
  data, `Assoc [ "artifact", U.member "artifact" data; "package_id", U.member "package_id" data ]
;;

let skill_path fixture package_id =
  Filename.concat (Filename.concat (Filename.concat fixture.base_path "skills") package_id)
    "SKILL.md"
;;

let published_reference response =
  U.(response |> member "preview" |> member "profile" |> member "reference")
;;

let create fixture ?token draft =
  http fixture ?token ~path:"/api/v1/skills/editor/create"
    (`Assoc [ "source_id", `String "workspace"; "draft", draft ])
;;

let test_validated_draft_round_trip () =
  with_fixture @@ fun fixture ->
  let source = instruction ~name:"proposed" ~description:"Inspect the lane status." in
  let validation, draft = validated_draft fixture ~package_id:"proposed" source in
  check bool "tool validated the draft" true (U.member "ok" validation = `Bool true);
  let status, response = create fixture ~token:fixture.admin draft in
  check int "admin create" 200 status;
  check string "published" "created_and_published" U.(member "status" response |> to_string);
  check string "exact exported bytes on disk" source (read_file (skill_path fixture "proposed"));
  let reference = published_reference response in
  check string "published revision is the exported bytes"
    (Skill_reference.content_revision_of_source_text source
     |> Skill_reference.content_revision_to_string)
    U.(member "content_revision" reference |> to_string);
  let edited = instruction ~name:"proposed" ~description:"Inspect the lane status first." in
  let _, edited_draft = validated_draft fixture ~package_id:"proposed" edited in
  let status, response =
    http fixture ~token:fixture.admin ~path:"/api/v1/skills/editor/save"
      (`Assoc [ "reference", reference; "draft", edited_draft ]) in
  check int "admin save" 200 status;
  check string "saved" "saved_and_published" U.(member "status" response |> to_string);
  check string "exact edited bytes on disk" edited (read_file (skill_path fixture "proposed"))
;;

let replace name value = function
  | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
  | _ -> fail "object fixture expected"
;;

let test_changed_or_unknown_artifact_is_refused () =
  with_fixture @@ fun fixture ->
  let source = instruction ~name:"proposed" ~description:"Inspect the lane status." in
  let _, draft = validated_draft fixture ~package_id:"proposed" source in
  let artifact = U.member "artifact" draft in
  let normalized = U.member "blob" artifact in
  let blob = U.member "_blob" normalized in
  let with_blob blob =
    replace "artifact" (replace "blob" (replace "_blob" blob normalized) artifact) draft in
  let refused label draft =
    let status, _ = create fixture ~token:fixture.admin draft in
    check int label 400 status;
    check bool (label ^ ": nothing written") false
      (Sys.file_exists (skill_path fixture "proposed"))
  in
  refused "unknown artifact"
    (with_blob (replace "sha256" (`String (String.make 64 '0')) blob));
  refused "size differs from the export"
    (with_blob (replace "bytes" (`Int (U.(member "bytes" blob |> to_int) + 1)) blob));
  refused "package the document does not name"
    (replace "package_id" (`String "another-package") draft);
  let status, _ =
    http fixture ~token:fixture.admin ~path:"/api/v1/skills/editor/create"
      (`Assoc [ "source_id", `String "workspace"; "draft", draft
              ; "source_text", `String source ]) in
  check int "draft and pasted text together" 400 status;
  let status, response = create fixture ~token:fixture.admin draft in
  check int "the untouched draft still publishes" 200 status;
  let reference = published_reference response in
  let _, other = validated_draft fixture ~package_id:"other"
      (instruction ~name:"other" ~description:"Another Skill.") in
  let status, _ =
    http fixture ~token:fixture.admin ~path:"/api/v1/skills/editor/save"
      (`Assoc [ "reference", reference; "draft", other ]) in
  check int "save refuses a draft for another package" 400 status;
  check string "saved Skill is unchanged" source (read_file (skill_path fixture "proposed"))
;;

let test_non_admin_is_refused () =
  with_fixture @@ fun fixture ->
  let source = instruction ~name:"proposed" ~description:"Inspect the lane status." in
  let _, draft = validated_draft fixture ~package_id:"proposed" source in
  let status, _ = create fixture draft in
  check int "anonymous" 401 status;
  let status, _ = create fixture ~token:fixture.worker draft in
  check int "worker" 403 status;
  check bool "nothing written" false (Sys.file_exists (skill_path fixture "proposed"))
;;

let () =
  run "Skill editor publishes validated drafts"
    [ "draft reference",
      [ test_case "validate, reference and publish the same bytes" `Quick
          test_validated_draft_round_trip
      ; test_case "changed or unknown artifact is refused" `Quick
          test_changed_or_unknown_artifact_is_refused
      ; test_case "non-admin is refused" `Quick test_non_admin_is_refused
      ] ]
;;
