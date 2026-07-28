(** Keeper_prompt_external — loader for behavior prompt blocks living
    in [<prompts_dir>/behavior/<name>.md].  See [.mli] for the
    contract. *)

module Mutex = Stdlib.Mutex

(* Successful prompt bodies are process-cached. A miss is observed once but is
   never cached as a value: operators can restore a missing behavior file and
   the next Keeper turn sees it without restarting the server. *)
let cache : (string, string) Hashtbl.t = Hashtbl.create 16
let observed_failures : (string, unit) Hashtbl.t = Hashtbl.create 16
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

type load_failure =
  | Missing of string
  | Read_failed of string

let load_uncached name =
  let path = behavior_path name in
  if Sys.file_exists path && not (Sys.is_directory path) then (
    match read_file path with
    | Some content -> Ok content
    | None -> Error (Read_failed path))
  else Error (Missing path)

let observe_failure = function
  | Read_failed path ->
    Log.Keeper.warn
      "keeper_prompt_external: failed to read %s (returning None; caller will \
       render config-drift marker; future turns will retry)"
      path
  | Missing path ->
    (* P1-4: missing external prompt files are expected during bootstrap.
       Log the first miss at INFO, then retry silently until the file appears. *)
    Log.Keeper.info
      "keeper_prompt_external: missing %s (returning None; caller will render \
       config-drift marker; future turns will retry)"
      path
;;

let get name =
  Mutex.lock cache_mutex;
  match Hashtbl.find_opt cache name with
  | Some cached ->
      Mutex.unlock cache_mutex;
      Some cached
  | None ->
      Mutex.unlock cache_mutex;
      (* Read outside the lock so concurrent first-time lookups for
         different names do not serialize on disk I/O.  Worst case:
         two domains read the same file once each before either
         caches; the resulting [Hashtbl.replace] is idempotent. *)
      let result = load_uncached name in
      Mutex.lock cache_mutex;
      (match result with
       | Ok content ->
         Hashtbl.replace cache name content;
         Hashtbl.remove observed_failures name;
         Mutex.unlock cache_mutex;
         Some content
       | Error failure ->
         (match Hashtbl.find_opt cache name with
          | Some content ->
            (* Another first reader restored and cached the same prompt while
               this read was in flight. Never return a stale miss after a
               process-local success is already authoritative. *)
            Mutex.unlock cache_mutex;
            Some content
          | None ->
            let first_failure = not (Hashtbl.mem observed_failures name) in
            Hashtbl.replace observed_failures name ();
            Mutex.unlock cache_mutex;
            if first_failure then observe_failure failure;
            None))

let reset_cache () =
  Mutex.lock cache_mutex;
  Hashtbl.clear cache;
  Hashtbl.clear observed_failures;
  Mutex.unlock cache_mutex
