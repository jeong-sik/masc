(** The bytes a store holds for the retained Lane instances RFC-0497 section
    4.1 would delete, for the instances it keeps, and under [observations] as a
    whole. The caller names the instances ({!Lane_addon_superseded.plan} decides
    them); this module only reads file sizes.

    Layer one: nothing reads the report to delete. *)

type report = {
  eligible : int;
  eligible_bytes : int64;
      (** The binding record, observation directory and action directory of
          each eligible instance. *)
  kept : int;
  kept_bytes : int64;  (** The same three for each kept instance. *)
  observations_bytes : int64;
      (** Every file under [observations], directories with no binding
          included. *)
}

val count :
  root:string -> eligible:string list -> kept:string list -> (report, string) result
(** Blocking: walks the directories with [lstat]; call it off the server
    domain. Regular files count their size. A path that does not exist counts
    zero, and a symbolic link is not followed. A directory that cannot be
    listed, or a path that cannot be read for another reason, refuses the
    whole count. *)
