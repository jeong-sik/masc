(** Keeper_prompt_external — loader for behavior prompt blocks living
    in [<prompts_dir>/behavior/<name>.md].  See [.mli] for the
    contract. *)

module Mutex = Stdlib.Mutex

(* Cache stores the *result* of the lookup (Some content or None) so
   missing-file lookups are not retried on every keeper turn — the
   warn fires once and subsequent calls return the same [None]. *)
let cache : (string, string option) Hashtbl.t = Hashtbl.create 16
let cache_mutex = Mutex.create ()

let behavior_path name =
  let prompts_dir = Config_dir_resolver.prompts_dir () in
  Filename.concat (Filename.concat prompts_dir "behavior") (name ^ ".md")

(* Strip a leading YAML frontmatter block ("---\n...\n---\n") if
   present so callers receive only the prompt body.  Keeps the loader
   independent of [Prompt_registry]'s internal frontmatter parser. *)
let strip_frontmatter (content : string) : string =
  let lines = String.split_on_char '\n' content in
  match lines with
  | first :: rest when String.trim first = "---" ->
      let rec drop_until_close = function
        | [] -> None
        | line :: remaining when String.trim line = "---" -> Some remaining
        | _ :: remaining -> drop_until_close remaining
      in
      (match drop_until_close rest with
       | Some body_lines ->
           (* Drop one leading blank line if the file uses "---\n\nbody" style. *)
           let body_lines =
             match body_lines with
             | "" :: tl -> tl
             | _ -> body_lines
           in
           String.concat "\n" body_lines
       | None -> content)
  | _ -> content

let read_file path =
  try
    let raw = Fs_compat.load_file path in
    Some (strip_frontmatter raw)
  with
  | Sys_error _ -> None

let load_uncached name =
  let path = behavior_path name in
  if Sys.file_exists path && not (Sys.is_directory path) then (
    match read_file path with
    | Some content -> Some content
    | None ->
        Log.Keeper.warn
          "keeper_prompt_external: failed to read %s (returning None; \
           caller will render config-drift marker)"
          path;
        None)
  else (
    (* P1-4: missing external prompt file is expected during startup when
       the operator's base-path config does not yet have the file.
       keeper_prompt.ml renders an explicit config-drift marker, so a WARN
       here fires on every startup and becomes noise. Downgrade to INFO so
       the path is visible but not alarming. *)
    Log.Keeper.info
      "keeper_prompt_external: missing %s (returning None; caller will \
       render config-drift marker)"
      path;
    None)

let get name =
  Mutex.lock cache_mutex;
  match Hashtbl.find_opt cache name with
  | Some cached ->
      Mutex.unlock cache_mutex;
      cached
  | None ->
      Mutex.unlock cache_mutex;
      (* Read outside the lock so concurrent first-time lookups for
         different names do not serialize on disk I/O.  Worst case:
         two domains read the same file once each before either
         caches; the resulting [Hashtbl.replace] is idempotent. *)
      let result = load_uncached name in
      Mutex.lock cache_mutex;
      Hashtbl.replace cache name result;
      Mutex.unlock cache_mutex;
      result

let reset_cache () =
  Mutex.lock cache_mutex;
  Hashtbl.clear cache;
  Mutex.unlock cache_mutex
