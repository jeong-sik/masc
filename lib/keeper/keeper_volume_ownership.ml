(* Workspace-scoped ownership for Apple Keeper volumes.

   Work and build volume names carry the Keeper name but not its workspace
   (RFC-0400), so same-named Keepers in different workspaces resolve to the
   same two disks on one Apple Container runtime store. {!val probe} reads
   what the runtime itself knows about a volume — `container volume inspect`
   plus the volume's ext4 superblock — and answers whether this workspace's
   identity is the one written on it, without creating, attaching, or
   deleting anything.

   The marker is a single file at the guest-visible volume root:
   [.masc-volume-owner]. It records the owning workspace's identity as the
   runtime writes it at first boot, and nothing else. Old volumes created
   before this convention carry no marker; they answer [Legacy_unmarked] and
   callers must keep treating them as unverified rather than guessing. *)

type owner_marker =
  { base_path : string  (** Workspace base path exactly as configured. *)
  ; written_at : float  (** Unix seconds, diagnostic only. *)
  }

(** Why a probe could not answer [Owned_by_this_workspace]. *)
type unverified =
  | Inspect_failed of string
    (** The runtime CLI failed, so nothing about the volume is known. *)
  | Unmarked
    (** The volume exists and is healthy but has no ownership marker; it
        predates the convention and may belong to any workspace. *)
  | Marker_io of string
    (** The volume image could not be opened to read the marker. *)
  | Marker_unreadable of string
    (** A marker exists but does not parse as the documented format. *)
  | Marker_mismatch of { recorded : string; probed : string }
    (** A marker names a different workspace than the one asking. *)

type t =
  | Owned_by_this_workspace
  | Unverified of unverified
  | Owned_by_another_workspace of { recorded : string }

let marker_path = ".masc-volume-owner"

let marker_to_yojson (m : owner_marker) =
  `Assoc
    [ ("base_path", `String m.base_path)
    ; ("written_at", `Float m.written_at)
    ; ("schema", `Int 1)
    ]
;;

let marker_of_yojson = function
  | `Assoc fields
    when List.exists (fun (k, _) -> String.equal k "base_path") fields
         && List.exists (fun (k, _) -> String.equal k "schema") fields ->
    (match List.assoc_opt "base_path" fields, List.assoc_opt "schema" fields with
     | Some (`String base_path), Some (`Int 1) when base_path <> "" ->
       Ok
         { base_path
         ; written_at =
             (match List.assoc_opt "written_at" fields with
              | Some (`Float at) -> at
              | _ -> 0.0)
         }
     | Some (`String _), Some (`Int schema) ->
       Error (Printf.sprintf "owner marker schema %d is not 1" schema)
     | _ -> Error "owner marker lacks base_path")
  | _ -> Error "owner marker is not a schema'd object"
;;

(* Reading the marker from a mounted volume is the runtime's job: this module
   only interprets bytes, so tests can drive it without any disk. The guest
   sees the volume at [/masc-work]; the runtime reads the same file through
   the host image when no guest holds it. Both sides share the format above.

   The disk path goes through {!Keeper_volume_filesystem} conventions: open
   read-only, refuse non-regular files, and never write. Reading cannot
   repair, attach, or delete anything; a failed read is [Marker_io], which is
   [Unverified], which callers already treat as preserve. *)

let interpret_marker_bytes ~probed_base_path (bytes : string) : t =
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error detail -> Unverified (Marker_unreadable detail)
  | json ->
    (match marker_of_yojson json with
     | Error detail -> Unverified (Marker_unreadable detail)
     | Ok marker ->
       if String.equal marker.base_path probed_base_path
       then Owned_by_this_workspace
       else Owned_by_another_workspace { recorded = marker.base_path })
;;

let interpret_marker_absent () : t = Unverified Unmarked

let unverified_to_string = function
  | Inspect_failed detail -> "volume inspect failed: " ^ detail
  | Unmarked -> "volume predates ownership markers; owner unknown"
  | Marker_io detail -> "owner marker unreadable (io): " ^ detail
  | Marker_unreadable detail -> "owner marker malformed: " ^ detail
  | Marker_mismatch { recorded; probed } ->
    Printf.sprintf
      "owner marker names %s but this workspace is %s"
      recorded
      probed
;;

