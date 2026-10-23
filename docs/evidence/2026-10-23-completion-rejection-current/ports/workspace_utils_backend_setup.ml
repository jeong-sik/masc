type config = {
  mutable snapshot : Masc_domain.backlog;
  mutable read_failure : string option;
  mutable write_failure : string option;
  mutable lock_failure : Masc_domain.boundary_error option;
  mutable lease_lost : bool;
  mutable lock_held : bool;
  mutable fence_held : bool;
  mutable read_attempts : int;
  mutable write_attempts : int;
  mutable committed_writes : int;
  mutable before_lock : (unit -> unit) option;
  mutable before_fence : (unit -> unit) option;
  mutable read_scopes : (bool * bool) list;
}
let make snapshot = { snapshot; read_failure=None; write_failure=None;
  lock_failure=None; lease_lost=false; lock_held=false; fence_held=false;
  read_attempts=0; write_attempts=0; committed_writes=0;
  before_lock=None; before_fence=None; read_scopes=[] }
