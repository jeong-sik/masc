type input =
  { path : string
  ; contents : string
  }

type recipe =
  { name : string
  ; dockerfile : string
  ; inputs : input list
  }

let base_embedded =
  { name = "base"; dockerfile = Keeper_sandbox_image.dockerfile; inputs = [] }

type load_error =
  | Invalid_name of string
  | Recipe_missing of { path : string }
  | Input_path_rejected of { listed_in : string; path : string }
  | Input_outside_source of { listed_in : string; path : string }
  | Input_missing of { listed_in : string; path : string }
  | Unreadable of { path : string; detail : string }
  | Context_unwritable of { path : string; detail : string }

let load_error_to_string = function
  | Invalid_name name ->
    Printf.sprintf
      "%S is not a recipe name: use lowercase letters, digits and '-', not \
       starting with '-'"
      name
  | Recipe_missing { path } -> Printf.sprintf "no recipe at %s" path
  | Input_path_rejected { listed_in; path } ->
    Printf.sprintf
      "%s lists %S, which is absolute, empty, climbs out with '..' or is the \
       recipe's own Dockerfile; an input is another path inside the checkout"
      listed_in path
  | Input_outside_source { listed_in; path } ->
    Printf.sprintf
      "%s lists %s, which a symbolic link resolves to a file outside the \
       checkout"
      listed_in path
  | Input_missing { listed_in; path } ->
    Printf.sprintf "%s lists %s, which does not exist" listed_in path
  | Unreadable { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Context_unwritable { path; detail } ->
    Printf.sprintf "cannot write the build context at %s: %s" path detail

let valid_name name =
  let allowed = function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false in
  String.length name > 0
  && (not (Char.equal name.[0] '-'))
  && String.for_all allowed name

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error detail -> Error (Unreadable { path; detail })

(* One path per line; blank lines and '#' comments are for the reader. *)
let listed_paths text =
  String.split_on_char '\n' text
  |> List.map String.trim
  |> List.filter (fun line ->
    String.length line > 0 && not (Char.equal line.[0] '#'))

(* The recipe's own Dockerfile sits at the context root, so an input listed
   under that name would overwrite it there. *)
let recipe_file_name = "Dockerfile"

let path_stays_inside path =
  String.length path > 0
  && Filename.is_relative path
  && (not (String.equal path recipe_file_name))
  && not (List.exists (String.equal "..") (String.split_on_char '/' path))

(* A path can be spelled inside the checkout and still resolve outside it
   through a symbolic link on the way. Both sides are resolved, so a checkout
   that is itself reached through a link still contains its own files. *)
let resolves_inside ~source full =
  match Unix.realpath source, Unix.realpath full with
  | root, target ->
    let prefix = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
    String.starts_with ~prefix target
  | exception Unix.Unix_error _ -> false

let load ~source ~name =
  let ( let* ) = Result.bind in
  let* () = if valid_name name then Ok () else Error (Invalid_name name) in
  let dir = Filename.concat (Filename.concat source "sandbox-images") name in
  let dockerfile_path = Filename.concat dir "Dockerfile" in
  let* () =
    if Sys.file_exists dockerfile_path then Ok ()
    else Error (Recipe_missing { path = dockerfile_path })
  in
  let* dockerfile = read_file dockerfile_path in
  let inputs_path = Filename.concat dir "inputs" in
  let* listed =
    if Sys.file_exists inputs_path then Result.map listed_paths (read_file inputs_path)
    else Ok []
  in
  let read_input path =
    let* () =
      if path_stays_inside path then Ok ()
      else Error (Input_path_rejected { listed_in = inputs_path; path })
    in
    let full = Filename.concat source path in
    let* () =
      if Sys.file_exists full then Ok ()
      else Error (Input_missing { listed_in = inputs_path; path })
    in
    let* () =
      if resolves_inside ~source full then Ok ()
      else Error (Input_outside_source { listed_in = inputs_path; path })
    in
    Result.map (fun contents -> { path; contents }) (read_file full)
  in
  let* inputs =
    List.fold_left
      (fun acc path ->
         let* read = acc in
         let* input = read_input path in
         Ok (input :: read))
      (Ok []) listed
  in
  Ok { name; dockerfile; inputs = List.rev inputs }

let tag_hash_prefix_length = 8

let inputs_sha256 recipe =
  let buf = Buffer.create 4096 in
  let frame part =
    Buffer.add_string buf (string_of_int (String.length part));
    Buffer.add_char buf ':';
    Buffer.add_string buf part
  in
  frame recipe.dockerfile;
  List.iter
    (fun input ->
       frame input.path;
       frame input.contents)
    recipe.inputs;
  Digestif.SHA256.(to_hex (digest_string (Buffer.contents buf)))

let repository recipe = "masc-sandbox-" ^ recipe.name

let build_minute built_at =
  let tm = Unix.gmtime built_at in
  Printf.sprintf "%04d%02d%02dT%02d%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min

let version ~built_at recipe =
  Printf.sprintf "%s-%s" (build_minute built_at)
    (String.sub (inputs_sha256 recipe) 0 tag_hash_prefix_length)

let tag ~built_at recipe =
  Printf.sprintf "%s:%s" (repository recipe) (version ~built_at recipe)

let rfc3339_utc built_at =
  let tm = Unix.gmtime built_at in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let labels ~version ~built_at recipe =
  [ "org.opencontainers.image.version", version
  ; "org.opencontainers.image.created", rfc3339_utc built_at
  ; "masc.sandbox.recipe", recipe.name
  ; "masc.sandbox.inputs_sha256", inputs_sha256 recipe
  ]

let rec make_parents dir =
  if not (Sys.file_exists dir) then begin
    make_parents (Filename.dirname dir);
    Sys.mkdir dir 0o700
  end

let write_file path contents =
  match
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
  with
  | () -> Ok ()
  | exception Sys_error detail -> Error (Context_unwritable { path; detail })

let write_context ~dir recipe =
  let ( let* ) = Result.bind in
  let dockerfile = Filename.concat dir recipe_file_name in
  let* () = write_file dockerfile recipe.dockerfile in
  let* () =
    List.fold_left
      (fun acc input ->
         let* () = acc in
         let target = Filename.concat dir input.path in
         let* () =
           match make_parents (Filename.dirname target) with
           | () -> Ok ()
           | exception Sys_error detail ->
             Error (Context_unwritable { path = Filename.dirname target; detail })
         in
         write_file target input.contents)
      (Ok ()) recipe.inputs
  in
  Ok dockerfile
