type entry_kind = Directory | File
type entry = { kind : entry_kind; path : string; mode : int; digest : string }

let release_directory_mode = 0o700
let release_file_mode = 0o644
let release_mode = function Directory -> release_directory_mode | File -> release_file_mode
let entry_kind_tag = function Directory -> "directory" | File -> "file"
let file_digest content = Digestif.SHA256.(to_hex (digest_string content))

(* Include directory entries and permissions: empty operator directories and
   chmod edits must not disappear merely because all file bytes still match. *)
let revision entries =
  entries
  |> List.map (fun { kind; path; mode; digest } -> entry_kind_tag kind, path, mode, digest)
  |> List.sort compare
  |> List.map (fun (kind, path, mode, digest) ->
    `List [ `String kind; `String path; `Int mode; `String digest ])
  |> (fun items -> `List items)
  |> Yojson.Safe.to_string |> file_digest

let directory_entries files =
  let rec parents path acc =
    let parent = Filename.dirname path in
    if parent = "." then acc else parents parent (parent :: acc)
  in
  List.fold_left (fun acc (path, _) -> parents path acc) [ "" ] files
  |> List.sort_uniq String.compare
  |> List.map (fun path ->
    { kind = Directory; path; mode = release_mode Directory; digest = "" })

let bundled_entries files =
  directory_entries files @ List.map (fun (path, content) ->
    { kind = File; path; mode = release_mode File; digest = file_digest content }) files

let with_release_modes entries =
  List.map (fun entry -> { entry with mode = release_mode entry.kind }) entries

(* Receipt and move-note format: the hex revision and a newline. *)
let recorded hex = hex ^ "\n"
