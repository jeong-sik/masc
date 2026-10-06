let () =
 let fixtures = Yojson.Safe.from_file Sys.argv.(1) |> Yojson.Safe.Util.to_assoc in
 List.iter (fun (name, json) -> match Tui_decode_lane_inventory.decode json with
 | Error error -> Printf.eprintf "FAIL %s: %s\n" name error; exit 1
 | Ok inventory -> Printf.printf "PASS %s: %d decoded rows\n" name (List.length inventory.rows)) fixtures
