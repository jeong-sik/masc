/* Interactive supervision must observe channel hangup even when its bounded
 * stdin queue is full. select(readfds) alone cannot do that without consuming
 * (and dropping) bytes. poll reports hangup independently of queued data. */
#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>

CAMLprim value ocaml_shim_stream_peer_state(value vfd)
{
  CAMLparam1(vfd);
  struct pollfd p = { .fd = Int_val(vfd), .events = 0, .revents = 0 };
#ifdef POLLRDHUP
  p.events |= POLLRDHUP;
#endif
  int result;
  do { result = poll(&p, 1, 0); } while (result < 0 && errno == EINTR);
  if (result < 0) uerror("poll", Nothing);
  /* The constant constructors of Shim_stream.peer_state, in declaration
     order. Full disconnect takes precedence over send-half-close. */
  if (result > 0 && (p.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0)
    CAMLreturn(Val_int(2));
#ifdef POLLRDHUP
  if (result > 0 && (p.revents & POLLRDHUP) != 0)
    CAMLreturn(Val_int(1));
#endif
  CAMLreturn(Val_int(0));
}

CAMLprim value ocaml_shim_set_nonblock(value vfd)
{
  CAMLparam1(vfd);
  int fd = Int_val(vfd);
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) uerror("fcntl(F_GETFL)", Nothing);
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
    uerror("fcntl(F_SETFL)", Nothing);
  CAMLreturn(Val_int(flags));
}

CAMLprim value ocaml_shim_restore_flags(value vfd, value vflags)
{
  CAMLparam2(vfd, vflags);
  if (fcntl(Int_val(vfd), F_SETFL, Int_val(vflags)) < 0)
    uerror("fcntl(F_SETFL)", Nothing);
  CAMLreturn(Val_unit);
}
