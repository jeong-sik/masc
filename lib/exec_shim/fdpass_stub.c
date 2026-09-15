/* fdpass_stub.c — SCM_RIGHTS file-descriptor passing for masc-exec-shim.
 *
 * ocaml_shim_send_fd : Unix.file_descr -> Unix.file_descr -> unit
 *   Sends [fd] as SCM_RIGHTS ancillary data over the connected unix-domain
 *   socket [sock], with a one-byte payload.  Raises Unix.Unix_error on
 *   failure.
 *
 * ocaml_shim_recv_fd : Unix.file_descr -> Unix.file_descr
 *   Receives one SCM_RIGHTS descriptor over [sock].  Raises Unix.Unix_error
 *   on failure, or Failure when the message carried no SCM_RIGHTS control
 *   data.
 *
 * Why a stub: OCaml's Unix module does not expose sendmsg/recvmsg ancillary
 * data, and a seccomp SECCOMP_FILTER_FLAG_NEW_LISTENER fd is created inside
 * the child — the filter must be installed there, not in the shim, so the
 * shim's own syscalls stay unrestricted.  The child hands that listener fd
 * to the shim over a unix-domain socket before exec; the shim then polls it
 * for SECCOMP_IOCTL_NOTIF_RECV.  See
 * docs/superpowers/specs/2026-09-14-refused-observe-observation-path-design.md
 * (task-1568 phase 2).
 */
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>

CAMLprim value ocaml_shim_send_fd(value vsock, value vfd)
{
  CAMLparam2(vsock, vfd);
  int sock = Int_val(vsock);
  int fd = Int_val(vfd);
  char payload = 'F';
  struct iovec iov;
  struct msghdr msg;
  char control[CMSG_SPACE(sizeof(int))];
  struct cmsghdr *cmsg;
  ssize_t sent;

  iov.iov_base = &payload;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  memset(control, 0, sizeof(control));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control;
  msg.msg_controllen = sizeof(control);
  cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

  do {
    sent = sendmsg(sock, &msg, 0);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0)
    uerror("sendmsg", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_shim_recv_fd(value vsock)
{
  CAMLparam1(vsock);
  int sock = Int_val(vsock);
  char payload;
  struct iovec iov;
  struct msghdr msg;
  char control[CMSG_SPACE(sizeof(int))];
  struct cmsghdr *cmsg;
  ssize_t got;
  int fd;

  iov.iov_base = &payload;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  memset(control, 0, sizeof(control));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control;
  msg.msg_controllen = sizeof(control);

  do {
    got = recvmsg(sock, &msg, 0);
  } while (got < 0 && errno == EINTR);
  if (got < 0)
    uerror("recvmsg", Nothing);
  cmsg = CMSG_FIRSTHDR(&msg);
  if (cmsg == NULL || cmsg->cmsg_level != SOL_SOCKET
      || cmsg->cmsg_type != SCM_RIGHTS
      || cmsg->cmsg_len < CMSG_LEN(sizeof(int)))
    caml_failwith("recvmsg: no SCM_RIGHTS descriptor");
  memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
  CAMLreturn(Val_int(fd));
}
