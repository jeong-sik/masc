#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <sys/socket.h>

CAMLprim value masc_endpoint_peer_supported(value unit)
{
  CAMLparam1(unit);
#ifdef __linux__
  CAMLreturn(Val_true);
#else
  CAMLreturn(Val_false);
#endif
}

CAMLprim value masc_endpoint_peer_credentials(value vfd)
{
  CAMLparam1(vfd);
  CAMLlocal2(tuple, some);
#ifdef __linux__
  int fd = Int_val(vfd), type;
  struct sockaddr_storage local, remote;
  struct ucred credentials;
  socklen_t length = sizeof(local);
  if (getsockname(fd, (struct sockaddr *)&local, &length) == -1) {
    if (errno == ENOTSOCK) CAMLreturn(Val_int(0));
    uerror("endpoint_peer_getsockname", Nothing);
  }
  if (local.ss_family != AF_UNIX) CAMLreturn(Val_int(0));
  length = sizeof(type);
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == -1)
    uerror("endpoint_peer_socket_type", Nothing);
  if (length != sizeof(type) || type != SOCK_STREAM) CAMLreturn(Val_int(0));
  length = sizeof(remote);
  if (getpeername(fd, (struct sockaddr *)&remote, &length) == -1)
    uerror("endpoint_peer_getpeername", Nothing);
  if (remote.ss_family != AF_UNIX) CAMLreturn(Val_int(0));
  length = sizeof(credentials);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == -1)
    uerror("endpoint_peer_credentials", Nothing);
  if (length != sizeof(credentials))
    unix_error(EIO, "endpoint_peer_credentials", Nothing);
  tuple = caml_alloc_tuple(3);
  Store_field(tuple, 0, Val_long(credentials.uid));
  Store_field(tuple, 1, Val_long(credentials.gid));
  Store_field(tuple, 2, Val_long(credentials.pid));
  some = caml_alloc(1, 0);
  Store_field(some, 0, tuple);
  CAMLreturn(some);
#else
  CAMLreturn(Val_int(0));
#endif
}
