type git_link =
  | Git_directory
  | Git_pointer_file

type checkout =
  { relative_path : string
  ; absolute_path : string
  ; name : string
  ; git_link : git_link
  }

type limit =
  | Entry_budget_exhausted of
      { scanned : int
      ; budget : int
      }
  | Checkout_budget_exhausted of { budget : int }
  | Directory_unreadable of
      { relative_path : string
      ; detail : string
      }

type scan_error =
  | Root_missing of { root : string }
  | Root_not_directory of
      { root : string
      ; kind : string
      }
  | Root_unreadable of
      { root : string
      ; detail : string
      }

type discovery =
  | Complete of checkout list
  | Partial of
      { found : checkout list
      ; limit : limit
      }

(* Measured across the live playground (12 keepers, 2026-08-13): worst case 495
   readdir entries over 107 directories (a keeper holding source-shaped
   artifacts outside any checkout), median 34. 8192 is roughly 16x the worst
   observation.

   This is a safety stop, not a tuning knob. A normal playground cannot reach
   it, so [Entry_budget_exhausted] is itself the anomaly signal — raise the
   ceiling only after understanding what produced that many entries. *)
let max_scanned_entries = 8_192

(* Bounded by what happens downstream, not by the walk: [checkout_json] spends
   six bounded git subprocesses per reported checkout, so 32 caps one status
   render at 192 spawns. The live maximum is 12 checkouts for one keeper.

   If this needs to grow, the thing to fix is running six git calls per
   checkout inline on an HTTP path, not this constant. *)
let max_reported_checkouts = 32

let file_kind_to_string : Unix.file_kind -> string = function
  | S_REG -> "regular file"
  | S_DIR -> "directory"
  | S_CHR -> "character device"
  | S_BLK -> "block device"
  | S_LNK -> "symlink"
  | S_FIFO -> "fifo"
  | S_SOCK -> "socket"
;;

let strip_trailing_slash path =
  let n = String.length path in
  if n > 1 && path.[n - 1] = '/' then String.sub path 0 (n - 1) else path
;;

(* [Fs_compat.exact_path_kind] reports a missing path as a value but raises on
   a permission error: lstat of a child under a mode-000 directory fails with
   EACCES. Both [Sys_error] and [Unix.Unix_error] are possible.

   "Cannot tell" is not "is not there", but at this point in the walk the two
   lead to the same local decision — do not classify this entry as a checkout.
   The condition still surfaces: the enclosing [read_dir] of that directory
   fails and becomes [Directory_unreadable], which the caller sees. *)
let path_kind_no_follow path =
  try Fs_compat.exact_path_kind ~follow:false path with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error _ | Unix.Unix_error _ -> Fs_compat.Exact_unknown
;;

let is_directory_no_follow abs =
  match path_kind_no_follow abs with
  | Fs_compat.Exact_kind Unix.S_DIR -> true
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_missing | Fs_compat.Exact_unknown ->
    false
;;

(* A [.git] symlink is rejected rather than followed: it can point outside the
   workspace root, and treating it as a checkout would attribute writes to a
   tree the keeper does not own. *)
let git_link_of_dir abs =
  match path_kind_no_follow (Filename.concat abs ".git") with
  | Fs_compat.Exact_kind Unix.S_DIR -> Some Git_directory
  | Fs_compat.Exact_kind Unix.S_REG -> Some Git_pointer_file
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_missing | Fs_compat.Exact_unknown ->
    None
;;

let relative_of_segments = function
  | [] -> "."
  | segments -> String.concat "/" segments
;;

let take n items =
  let rec go acc n = function
    | item :: rest when n > 0 -> go (item :: acc) (n - 1) rest
    | _ -> List.rev acc
  in
  go [] n items
;;

let sort_by_relative_path checkouts =
  List.sort
    (fun a b -> String.compare a.relative_path b.relative_path)
    checkouts
;;

(* Internal control flow for the walk below. [Truncated] carries a partial but
   real result; [Root_read_failed] means there is no result at all, which is a
   different answer and must not collapse into an empty list. *)
exception Truncated of limit
exception Root_read_failed of string

let discover ~root =
  let root = strip_trailing_slash root in
  (* Unlike the entries below, a root that cannot be stat'ed is reported as
     unreadable rather than as "not a directory" — the caller needs to tell a
     permission problem from a wrong path. *)
  match
    try Ok (Fs_compat.exact_path_kind ~follow:false root) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error detail -> Error detail
    | Unix.Unix_error (code, operation, _) ->
      Error (Printf.sprintf "%s: %s" operation (Unix.error_message code))
  with
  | Error detail -> Error (Root_unreadable { root; detail })
  | Ok root_kind ->
  match root_kind with
  | Fs_compat.Exact_missing -> Error (Root_missing { root })
  | Fs_compat.Exact_unknown ->
    Error (Root_not_directory { root; kind = "unknown" })
  | Fs_compat.Exact_kind Unix.S_DIR ->
    (* The root itself may be the checkout. Answer that before walking, so a
       keeper that clones straight into its workspace root is not a blind
       spot. *)
    (match git_link_of_dir root with
     | Some git_link ->
       Ok
         (Complete
            [ { relative_path = "."
              ; absolute_path = root
              ; name = Filename.basename root
              ; git_link
              }
            ])
     | None ->
       let queue = Queue.create () in
       Queue.add [] queue;
       let scanned = ref 0 in
       let found = ref [] in
       let found_count = ref 0 in
       let truncation = ref None in
       let unreadable = ref None in
       let root_error = ref None in
       (try
          while not (Queue.is_empty queue) do
            let segments = Queue.pop queue in
            let relative = relative_of_segments segments in
            let absolute =
              match segments with
              | [] -> root
              | _ -> Filename.concat root relative
            in
            (* One yield per directory. The walk runs on the same domain fiber
               that serves HTTP, and a long uninterrupted walk would starve
               other requests between them. *)
            Eio_guard.fair_yield ();
            let entries =
              let fail detail =
                match segments with
                | [] -> raise (Root_read_failed detail)
                | _ ->
                  (* Skip this subtree and keep walking. Ending the scan here
                     would drop every checkout the traversal had not reached
                     yet — with breadth-first order that is whatever sorts
                     after the unreadable directory, which is arbitrary. The
                     listing narrows; it does not stop. *)
                  if Option.is_none !unreadable
                  then
                    unreadable
                    := Some (Directory_unreadable { relative_path = relative; detail });
                  []
              in
              try Fs_compat.read_dir absolute with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | Sys_error detail -> fail detail
              | Unix.Unix_error (code, operation, _) ->
                fail (Printf.sprintf "%s: %s" operation (Unix.error_message code))
            in
            scanned := !scanned + List.length entries;
            if !scanned > max_scanned_entries
            then
              raise
                (Truncated
                   (Entry_budget_exhausted
                      { scanned = !scanned; budget = max_scanned_entries }));
            List.iter
              (fun entry ->
                 if not (String.equal entry "." || String.equal entry "..")
                 then (
                   let child_segments = segments @ [ entry ] in
                   let child_abs = Filename.concat absolute entry in
                   if is_directory_no_follow child_abs
                   then (
                     match git_link_of_dir child_abs with
                     | Some git_link ->
                       (* Found a checkout: do not descend. Its subtree belongs
                          to it, which is what keeps _build/.sandbox/.git and
                          node_modules out without naming them. *)
                       found
                       := { relative_path = relative_of_segments child_segments
                          ; absolute_path = child_abs
                          ; name = entry
                          ; git_link
                          }
                          :: !found;
                       incr found_count;
                       if !found_count > max_reported_checkouts
                       then
                         raise
                           (Truncated
                              (Checkout_budget_exhausted
                                 { budget = max_reported_checkouts }))
                     | None -> Queue.add child_segments queue)))
              entries
          done
        with
        | Truncated limit -> truncation := Some limit
        | Root_read_failed detail -> root_error := Some detail);
       (match !root_error with
        | Some detail -> Error (Root_unreadable { root; detail })
        | None ->
          (* A budget stop is reported ahead of an unreadable directory: it
             bounds the whole listing, while the latter bounds one subtree. *)
          (match !truncation, !unreadable with
           | None, None -> Ok (Complete (sort_by_relative_path !found))
           | Some limit, _ | None, Some limit ->
             Ok
               (Partial
                  { found =
                      take max_reported_checkouts (sort_by_relative_path !found)
                  ; limit
                  }))))
  | Fs_compat.Exact_kind kind ->
    Error (Root_not_directory { root; kind = file_kind_to_string kind })
;;

let found = function
  | Complete checkouts -> checkouts
  | Partial { found; _ } -> found
;;

let join checkout ~suffix =
  match String.equal checkout.relative_path ".", String.equal suffix "" with
  | true, true -> "."
  | true, false -> suffix
  | false, true -> checkout.relative_path
  | false, false -> Filename.concat checkout.relative_path suffix
;;

type name_resolution =
  | Resolved of checkout
  | Not_found
  | Ambiguous of checkout list

let resolve_by_name discovery ~name =
  match List.filter (fun c -> String.equal c.name name) (found discovery) with
  | [ checkout ] -> Resolved checkout
  | [] -> Not_found
  | many -> Ambiguous many
;;

let limit_to_string = function
  | Entry_budget_exhausted { scanned; budget } ->
    Printf.sprintf "entry budget exhausted (scanned %d, budget %d)" scanned budget
  | Checkout_budget_exhausted { budget } ->
    Printf.sprintf "checkout budget exhausted (budget %d)" budget
  | Directory_unreadable { relative_path; detail } ->
    Printf.sprintf "directory unreadable at %s: %s" relative_path detail
;;

let scan_error_to_string = function
  | Root_missing { root } -> Printf.sprintf "workspace root missing: %s" root
  | Root_not_directory { root; kind } ->
    Printf.sprintf "workspace root is a %s, not a directory: %s" kind root
  | Root_unreadable { root; detail } ->
    Printf.sprintf "workspace root unreadable: %s: %s" root detail
;;

let limit_code = function
  | Entry_budget_exhausted _ -> "entry_budget"
  | Checkout_budget_exhausted _ -> "checkout_budget"
  | Directory_unreadable _ -> "directory_unreadable"
;;

let scan_json (result : (discovery, scan_error) result) : Yojson.Safe.t =
  match result with
  | Ok (Complete _) ->
    `Assoc
      [ "state", `String "complete"
      ; "limit", `Null
      ; "detail", `Null
      ; "scanned_entries", `Null
      ]
  | Ok (Partial { limit; _ }) ->
    `Assoc
      [ "state", `String "partial"
      ; "limit", `String (limit_code limit)
      ; "detail", `String (limit_to_string limit)
      ; ( "scanned_entries"
        , match limit with
          | Entry_budget_exhausted { scanned; _ } -> `Int scanned
          | Checkout_budget_exhausted _ | Directory_unreadable _ -> `Null )
      ]
  | Error error ->
    `Assoc
      [ "state", `String "unavailable"
      ; "limit", `Null
      ; "detail", `String (scan_error_to_string error)
      ; "scanned_entries", `Null
      ]
;;
