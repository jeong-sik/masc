open Masc
let () =
  let root=Sys.getenv "MASC_BASE_PATH" in
  if not(Sys.file_exists(Filename.concat root "owned-fixture-marker")) then failwith "not owned fixture";
  let prompts=Filename.concat root "prompts" in Fs_compat.mkdir_p prompts;
  Fs_compat.save_file(Filename.concat prompts(Prompt_names.workspace_memory_briefing ^ ".md"))
    "---\ndescription: fixture\ncategory: test\n---\nSynthetic workspace briefing";
  Prompt_registry.clear ();Prompt_registry.set_markdown_dir prompts
