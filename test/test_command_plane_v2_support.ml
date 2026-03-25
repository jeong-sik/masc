open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_command_plane_v2_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755

let write_json_file path json =
  ensure_dir (Filename.dirname path);
  Yojson.Safe.to_file path json

let write_text_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_eio_test base_dir f =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config base_dir in
  f config

let unwrap_ok = function
  | Ok value -> value
  | Error message -> failwith message

let unit_update_exn config ~actor args =
  ignore (unwrap_ok (Command_plane_v2.unit_update_json config ~actor args))

let start_operation_exn config ~actor args =
  unwrap_ok (Command_plane_v2.start_operation config ~actor args)

let setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two =
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
  ignore (Room.join config ~agent_name:alpha_lead ~capabilities:[] ());
  ignore (Room.join config ~agent_name:alpha_two ~capabilities:[] ());
  unit_update_exn config ~actor:"owner"
    (`Assoc
      [
        ("unit_id", `String "company-main");
        ("kind", `String "company");
        ("label", `String "Main Company");
        ("leader_id", `String owner);
        ("roster", `List [ `String owner; `String alpha_lead; `String alpha_two ]);
      ]);
  unit_update_exn config ~actor:"owner"
    (`Assoc
      [
        ("unit_id", `String "platoon-alpha");
        ("kind", `String "platoon");
        ("label", `String "Alpha Platoon");
        ("parent_unit_id", `String "company-main");
        ("leader_id", `String alpha_lead);
        ("roster", `List [ `String alpha_lead; `String alpha_two ]);
      ])

let detachment_rows_for_operation config operation_id =
  Command_plane_v2.list_detachments_json ~operation_id config
  |> Yojson.Safe.Util.member "detachments"
  |> Yojson.Safe.Util.to_list

