let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; path ] ->
    Printf.printf
      "(* Generated from the OAS-owned models.toml. Do not edit. *)\nlet contents = %S\n"
      (read_file path)
  | argv ->
    Printf.eprintf
      "model_catalog_embed_gen: expected exactly one models.toml path, received %d\n"
      (List.length argv - 1);
    exit 64
;;
