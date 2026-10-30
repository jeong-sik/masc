(** The link graph of a wiki directory. Pure: nodes in, answers out.

    Results do not depend on the order the nodes were given in. *)

type node =
  | Readable of
      { page : string  (** The page name, without [.md]. *)
      ; links : Wiki_link.link list
      ; sources : Wiki_sources.t
      ; revision : int  (** The [revision] header the page carries. *)
      }
  | Unreadable of
      { file : string  (** [<name>.md]. *)
      ; reason : string  (** Why its header does not read. *)
      }

type t

val of_nodes : node list -> t

val readable_pages : t -> string list
(** Names of the pages whose header reads, in name order. *)

val unreadable_files : t -> (string * string) list
(** [(file, reason)] of the files whose header does not read, in file name
    order. *)

val file_exists : t -> string -> bool
(** Whether a page file named [<name>.md] is among the nodes, readable or
    not. *)

val links_of : t -> string -> Wiki_link.link list
(** The links of one readable page, in reading order. [[]] for a page that is
    not readable or not there. *)

val sources_of : t -> string -> Wiki_sources.t option
(** [None] for a page that is not readable or not there. *)

val revision_of : t -> string -> int option
(** The revision header of one readable page. [None] for a page that is not
    readable or not there. *)

val incoming : t -> string -> int
(** How many readable pages other than [name] itself link to it with a
    {!Wiki_link.Page} target. A page counts once per linking page. *)
