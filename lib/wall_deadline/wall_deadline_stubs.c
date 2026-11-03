#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#elif defined(__linux__)
#include <sys/timerfd.h>
#endif

struct timer_handle {
  int fd;
#if defined(__APPLE__)
  dispatch_source_t source;
#endif
};

static void close_timer(struct timer_handle *handle) {
#if defined(__APPLE__)
  if (handle->source) {
    dispatch_source_cancel(handle->source);
    dispatch_release(handle->source);
    handle->source = NULL;
  }
#endif
  if (handle->fd >= 0) {
    close(handle->fd);
    handle->fd = -1;
  }
}

static void finalize_timer(value raw) { close_timer(Data_custom_val(raw)); }

static struct custom_operations timer_operations = {
  .identifier = "masc.wall_deadline.v1",
  .finalize = finalize_timer,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default
};

#if defined(__APPLE__)
struct timer_context { int writer; int retained_reader; };

static void timer_fired(void *raw) {
  struct timer_context *context = raw;
  char byte = 1;
  ssize_t written;
  do { written = write(context->writer, &byte, 1); }
  while (written < 0 && errno == EINTR);
}

static void timer_canceled(void *raw) {
  struct timer_context *context = raw;
  close(context->writer);
  close(context->retained_reader);
  free(context);
}

static int nonblocking_cloexec(int fd) {
  int status = fcntl(fd, F_GETFL);
  int descriptor_flags = fcntl(fd, F_GETFD);
  if (status < 0 || descriptor_flags < 0) return -1;
  if (fcntl(fd, F_SETFL, status | O_NONBLOCK) < 0) return -1;
  return fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC);
}
#endif

CAMLprim value masc_wall_deadline_create(value deadline_value) {
  CAMLparam1(deadline_value);
  CAMLlocal1(raw);
  double deadline = Double_val(deadline_value);
  if (!isfinite(deadline) || deadline <= 0.0)
    caml_invalid_argument("wall deadline must be finite and positive");

  /* dispatch_walltime uses signed nanoseconds. An exceptionally distant
     deadline is rechecked when the largest representable instant arrives. */
  const double max_seconds = (double)(INT64_MAX / INT64_C(1000000000) - 1);
  if (deadline > max_seconds) {
    if ((double)time(NULL) >= max_seconds) {
      errno = EOVERFLOW;
      uerror("wall deadline range", Nothing);
    }
    deadline = max_seconds;
  }
  time_t seconds = (time_t)deadline;
  struct timespec when = {
    .tv_sec = seconds,
    .tv_nsec = (long)((deadline - (double)seconds) * 1000000000.0)
  };

  raw = caml_alloc_custom(&timer_operations, sizeof(struct timer_handle), 0, 1);
  struct timer_handle *handle = Data_custom_val(raw);
  handle->fd = -1;
#if defined(__APPLE__)
  handle->source = NULL;
  int fds[2];
  if (pipe(fds) < 0) uerror("wall deadline pipe", Nothing);
  if (nonblocking_cloexec(fds[0]) < 0 || nonblocking_cloexec(fds[1]) < 0) {
    int saved = errno; close(fds[0]); close(fds[1]); errno = saved;
    uerror("wall deadline pipe flags", Nothing);
  }
  int retained_reader = fcntl(fds[0], F_DUPFD_CLOEXEC, 0);
  if (retained_reader < 0) {
    int saved = errno; close(fds[0]); close(fds[1]); errno = saved;
    uerror("wall deadline reader", Nothing);
  }
  struct timer_context *context = malloc(sizeof(*context));
  if (!context) {
    close(retained_reader); close(fds[0]); close(fds[1]);
    caml_raise_out_of_memory();
  }
  context->writer = fds[1];
  context->retained_reader = retained_reader;
  dispatch_queue_t queue = dispatch_queue_create("masc.wall_deadline", DISPATCH_QUEUE_SERIAL);
  dispatch_source_t source = queue ? dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue) : NULL;
  if (!source) {
    if (queue) dispatch_release(queue);
    close(retained_reader); close(fds[0]); close(fds[1]); free(context);
    caml_raise_out_of_memory();
  }
  dispatch_set_context(source, context);
  dispatch_source_set_event_handler_f(source, timer_fired);
  dispatch_source_set_cancel_handler_f(source, timer_canceled);
  dispatch_source_set_timer(source, dispatch_walltime(&when, 0), DISPATCH_TIME_FOREVER, 0);
  handle->fd = fds[0];
  handle->source = source;
  dispatch_resume(source);
  dispatch_release(queue);
#elif defined(__linux__)
  int fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
  if (fd < 0) uerror("wall deadline timerfd", Nothing);
  struct itimerspec spec = { .it_value = when };
  if (timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &spec, NULL) < 0) {
    int saved = errno; close(fd); errno = saved;
    uerror("wall deadline arm", Nothing);
  }
  handle->fd = fd;
#else
  errno = ENOSYS;
  uerror("wall deadline unsupported", Nothing);
#endif
  CAMLreturn(raw);
}

CAMLprim value masc_wall_deadline_descriptor(value raw) {
  CAMLparam1(raw);
  struct timer_handle *handle = Data_custom_val(raw);
  if (handle->fd < 0) caml_invalid_argument("wall deadline is closed");
  CAMLreturn(Val_int(handle->fd));
}

CAMLprim value masc_wall_deadline_close(value raw) {
  CAMLparam1(raw);
  close_timer(Data_custom_val(raw));
  CAMLreturn(Val_unit);
}
