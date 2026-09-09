(* Prints, for every model row in the embedded catalog, what the row declares
   and what capability resolution answers for it. Not a test: it dumps, and
   the caller diffs two runs or reads one.

   Written 2026-09-07 to settle why Backend_gemini refused a reasoning_effort
   on gemini-3.8-flash. The row declares low|medium|high; resolution answers
   with none. The same holds for gemini-3.7-flash and for claude-fable-5,
   whose row declares low|medium|high|xhigh|max. So it is not one row and not
   one provider.

   Run it after any change to the lookup or the override merge:

     dune build packages/agent_core/test/capability_resolution_dump.exe
     ./_build/default/packages/agent_core/test/capability_resolution_dump.exe *)

module Model_catalog = Llm_provider.Model_catalog
module Capabilities = Llm_provider.Capabilities

let describe (caps : Capabilities.capabilities option) =
  match caps with
  | None -> "none"
  | Some c ->
    Printf.sprintf
      "budget=%b efforts=%s"
      c.supports_reasoning_budget
      (match c.accepted_reasoning_efforts with
       | None -> "-"
       | Some [] -> "[]"
       | Some l ->
         String.concat "|" (List.map Llm_provider.Reasoning_effort.to_string l))
;;

let () =
  match Model_catalog.load_default () with
  | Error detail ->
    Printf.eprintf "embedded catalog unavailable: %s\n" detail;
    exit 1
  | Ok catalog ->
    Model_catalog.set_global catalog;
    print_endline "id_prefix\tlabel\trow_efforts\tresolved";
    List.iter
      (fun (row : Model_catalog.model_entry) ->
        (* The label this row would be asked under: the provider it names, or
           its own capability base when it names none. *)
        let label =
          match row.provider_name, row.base_label with
          | Some p, _ -> p
          | None, Some b -> b
          | None, None -> "?"
        in
        let resolved =
          Capabilities.for_provider_model_id
            ~wire:None
            ~allow_bare_fallback:true
            ~provider_label:label
            ~model_id:row.id_prefix
        in
        Printf.printf
          "%s\t%s\t%s\t%s\n"
          row.id_prefix
          label
          (match row.accepted_reasoning_efforts with
           | None -> "-"
           | Some l -> String.concat "|" l)
          (describe resolved))
      (Model_catalog.model_entries catalog)
;;
