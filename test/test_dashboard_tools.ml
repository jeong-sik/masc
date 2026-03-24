(** Dashboard tools projection regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_tools" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let test_dashboard_tools_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun _env ->
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "dashboard"));
      let json = Lib.Server_dashboard_http.dashboard_tools_http_json config in
      let open Yojson.Safe.Util in
      let inventory = json |> member "tool_inventory" in
      let inventory_rows = inventory |> member "tools" |> to_list in
      let usage = json |> member "tool_usage" in
      check bool "inventory has tools" true (List.length inventory_rows > 0);
      (* Verify registered_count is a valid integer field *)
      let reg_count = usage |> member "registered_count" |> to_int in
      check bool "registered_count is non-negative" true (reg_count >= 0);
      check bool "usage dispatch flag present" true
        (match usage |> member "dispatch_v2_enabled" with
         | `Bool _ -> true
         | _ -> false);
      let hidden_tool =
        inventory_rows
        |> List.find_opt (fun row ->
               row |> member "name" |> to_string = "masc_goal_upsert")
      in
      check bool "includes hidden tool" true (Option.is_some hidden_tool);
      match hidden_tool with
      | None -> ()
      | Some row ->
          check string "visibility surfaced" "hidden"
            (row |> member "visibility" |> to_string);
          check string "lifecycle surfaced" "active"
            (row |> member "lifecycle" |> to_string);
          check bool "direct call flag surfaced" true
            (row |> member "direct_call_allowed" |> to_bool))

let () =
  run "dashboard_tools"
    [
      ("projection", [
           test_case "full inventory + usage summary" `Quick
             test_dashboard_tools_projection;
         ]);
    ]
