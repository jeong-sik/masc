open Asttypes
open Parsetree
let read path =
  let channel = open_in path in
  let lexbuf = Lexing.from_channel channel in
  Location.init lexbuf path;
  Fun.protect ~finally:(fun () -> close_in channel) (fun () -> Parse.implementation lexbuf)
let () =
  let mode = Sys.argv.(1) and path = Sys.argv.(2) in
  let source = read path in
  let output =
    match mode with
    | "strip" ->
      let removed = ref 0 in
      let mapper = { Ast_mapper.default_mapper with
        structure = (fun self items ->
          let retained = List.filter (fun item -> match item.pstr_desc with
            | Pstr_extension (({txt=("test" | "test_unit" | "test_module");_},_),_) -> incr removed; false
            | _ -> true) items in
          Ast_mapper.default_mapper.structure self retained) } in
      let clean = mapper.structure mapper source in
      Printf.eprintf "%s: removed %d inline-test extensions only\n" path !removed;
      clean
    | "helpers" | "exact" ->
      let wanted = if mode="helpers" then ["catalog";"manifest";"provider"] else ["test_exact_frozen_contract"] in
      let found = ref [] in
      let iterator = { Ast_iterator.default_iterator with
        value_binding = (fun self binding ->
          (match binding.pvb_pat.ppat_desc with
           | Ppat_var {txt=name;_} when List.mem name wanted -> found := (name,binding)::!found
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self binding) } in
      iterator.structure iterator source;
      List.map (fun name ->
        match List.filter (fun (key,_) -> key=name) !found with
        | [_,binding] -> Ast_helper.Str.value Nonrecursive [binding]
        | _ -> failwith ("expected one original helper " ^ name)) wanted
    | _ -> failwith "unknown preparation mode" in
  Format.printf "%a@." Pprintast.structure output
