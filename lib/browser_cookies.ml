open Result.Syntax
let cookies_limit = 200

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

(* The attributes that scope a cookie. [value] is not among them. *)
let kept_keys = [ "name"; "domain"; "path"; "secure"; "httpOnly"; "sameSite"; "expiry" ]

let project cookie =
  match field "name" cookie with
  | Some (`String _) ->
    (match cookie with
     | `Assoc fields -> Ok (`Assoc (List.filter (fun (key, _) -> List.mem key kept_keys) fields))
     | _ -> Error "WebDriver cookie is not an object")
  | _ -> Error "WebDriver cookie has no name"

let of_driver = function
  | `List cookies ->
    let* rows = List.fold_left (fun acc cookie ->
      let* rows = acc in
      let* row = project cookie in
      Ok (row :: rows)) (Ok []) cookies in
    let rows = List.rev rows in
    Ok (`Assoc [ "cookies", `List (List.filteri (fun index _ -> index < cookies_limit) rows)
               ; "total", `Int (List.length rows); "valuesWithheld", `Bool true ])
  | _ -> Error "WebDriver cookies are not a list"

(* The names web storage holds for the page's origin, never the values. A key
   name can be a hint, so only names and counts leave the page; each name is
   cut at [storage_name_chars] and at most [storage_names_limit] are listed. *)
let storage_names_limit = 100
let storage_name_chars = 200

let area_script area = Printf.sprintf {js|try {
  const store = window.%s;
  const keys = [];
  for (let index = 0; index < Math.min(store.length, %d); index++) keys.push(String(store.key(index)).slice(0, %d));
  return {count: store.length, keys: keys, truncated: store.length > %d};
} catch (error) { return {error: String(error && error.name || error)}; }|js} area storage_names_limit storage_name_chars storage_names_limit

(* One synchronous script: the origin and the two web storage areas. *)
let storage_script =
  "const local = (function(){" ^ area_script "localStorage" ^ "})();\n" ^
  "const session = (function(){" ^ area_script "sessionStorage" ^ "})();\n" ^
  "return {origin: location.origin, localStorage: local, sessionStorage: session};"

(* IndexedDB lists its databases through a promise, so this one is async: the
   last argument is the WebDriver callback. A page that never answers is cut
   at two seconds. *)
let indexeddb_script = Printf.sprintf {js|const done = arguments[arguments.length - 1];
if (!window.indexedDB || typeof indexedDB.databases !== "function") { done({unsupported: true}); return; }
Promise.race([indexedDB.databases(), new Promise(function(resolve){ setTimeout(function(){ resolve(null); }, 2000); })])
  .then(function(databases){
    if (databases === null) { done({error: "timeout"}); return; }
    done({count: databases.length,
      names: databases.slice(0, %d).map(function(db){ return String(db.name).slice(0, %d); }),
      truncated: databases.length > %d});
  }, function(error){ done({error: String(error && error.name || error)}); });|js} storage_names_limit storage_name_chars storage_names_limit

(* Adds the storage names to a projected cookie reply under [storage]. *)
let with_storage ~web ~indexeddb = function
  | `Assoc fields ->
    let storage = match web with
      | `Assoc web_fields -> `Assoc (web_fields @ ["indexedDb", indexeddb])
      | other -> `Assoc ["web", other; "indexedDb", indexeddb] in
    `Assoc (fields @ ["storage", storage; "storageValuesWithheld", `Bool true])
  | other -> other
