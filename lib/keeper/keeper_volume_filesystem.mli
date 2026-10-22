(** The ext4 error state the kernel recorded in a Keeper volume's superblock
    (RFC keeper-volume-filesystem-repair §3.1).

    Apple [container] keeps each Keeper volume as an ext4 image on the host.
    When the guest kernel meets a filesystem error it sets the superblock's
    "Errors detected" state bit and records the first and last error. This
    module reads that record from the host, without running anything in the
    guest, and while a guest may still have the volume mounted: the kernel
    writes the record as the errors happen (measured 2026-10-22,
    docs/evidence/2026-10-22-keeper-volume-fsck/).

    Field offsets follow
    https://www.kernel.org/doc/html/latest/filesystems/ext4/super.html *)

(** The architecture-independent cause the kernel stores beside each error
    site ([EXT4_ERR_*] in fs/ext4/ext4.h). [Not_recorded] is 0; a value the
    kernel may add later keeps its number in [Unrecognized]. *)
type error_code =
  | Not_recorded
  | Unknown
  | Eio
  | Enomem
  | Efsbadcrc
  | Efscorrupted
  | Enospc
  | Enokey
  | Erofs
  | Efbig
  | Eexist
  | Erange
  | Eoverflow
  | Ebusy
  | Enotdir
  | Enotempty
  | Eshutdown
  | Efault
  | Unrecognized of int

type error_site =
  { at : float  (** Seconds since the epoch, from the 40-bit time field. *)
  ; func : string  (** Kernel function that reported the error. *)
  ; line : int
  ; inode : int  (** 0 when the error named no inode. *)
  ; block : Int64.t  (** 0 when the error named no block. *)
  ; code : error_code
  }

(** Whether the filesystem needs [e2fsck]. The state bit alone decides; the
    count and sites are the evidence that goes with it. A site whose time
    field is 0 was never recorded and is [None]. *)
type state =
  | Clean
  | Errors_recorded of
      { count : int
      ; first : error_site option
      ; last : error_site option
      }

type read_failure =
  | Not_ext4 of { magic : int }  (** The magic field is not 0xEF53. *)
  | Truncated of { bytes : int }  (** Fewer superblock bytes than its size. *)
  | Unreadable of string  (** The image could not be opened or read. *)

(** The host image behind one [container] volume. *)
type image =
  { volume : string
  ; source : string  (** Host path of the image file. *)
  }

val superblock_offset : int
(** Byte offset of the primary superblock in the image. *)

val superblock_size : int

val of_superblock : string -> (state, read_failure) result
(** Decode one superblock. The argument is exactly the [superblock_size]
    bytes read at [superblock_offset]; a shorter string is [Truncated]. *)

val read_image : path:string -> (state, read_failure) result
(** Read and decode the superblock of the image at [path]. Blocking file
    I/O of one superblock; a caller on an Eio domain runs it off the
    scheduler. *)

val image_of_inspect : Yojson.Safe.t -> (image, string) result
(** The image named by [container volume inspect <volume>] output: an array
    holding one object whose [configuration] carries [name], [format] and
    [source]. A volume whose format is not [ext4] has no superblock to read
    and is an [Error]. *)

val error_code_to_string : error_code -> string
val state_to_yojson : state -> Yojson.Safe.t
val read_failure_to_string : read_failure -> string
