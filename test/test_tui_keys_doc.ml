(** The committed key reference must agree with the binding registry.
    docs/guides/TUI-KEYS.md is generated from [Masc_tui_keys]; a registry
    change that does not regenerate the document fails here rather than
    shipping a stale guide. The committed path arrives as argv because the
    document lives outside the test directory. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let () =
  match Sys.argv with
  | [| _; path |] ->
    let committed = read_file path in
    let generated = Masc_tui_keys_doc.markdown () in
    if not (String.equal committed generated) then begin
      Printf.eprintf
        "docs/guides/TUI-KEYS.md disagrees with bin/masc_tui_keys.ml.\n\
         Regenerate: dune exec bin/masc_tui_keys_doc_cli.exe > docs/guides/TUI-KEYS.md\n";
      exit 1
    end
  | _ ->
    Printf.eprintf "usage: test_tui_keys_doc <committed doc path>\n";
    exit 2
