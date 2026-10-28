#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/capability.h>
#include <linux/sched.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#endif

/* Fixed private descriptor layout; all source descriptors are first copied
   above it. This is not a wire-controlled descriptor map. */
enum { CTL_FD=3, CWD_FD=4, FIRST_SOURCE_FD=CWD_FD+1 };
enum stage {
  ST_ALLOC=1, ST_DUP, ST_OPEN, ST_GATE, ST_MASK, ST_CLONE,
  ST_CHILD_DUP, ST_CHILD_CLOSE, ST_CHILD_SESSION, ST_CHILD_CWD,
  ST_CHILD_CREDENTIALS, ST_CHILD_CAPS, ST_CHILD_SIGNALS,
  ST_CHILD_READY, ST_CHILD_GATE, ST_CHILD_EXEC,
  ST_CONTROL, ST_SIGNAL, ST_WAIT, ST_CLOSE, ST_WATCH, ST_DUP_GROUP
};
struct handle { int pidfd; int control; };
static void finalize_handle(value raw) {
  struct handle *h=Data_custom_val(raw);
  if (h->control>=0) close(h->control);
  if (h->pidfd>=0) close(h->pidfd);
  h->control=-1;h->pidfd=-1;
}
static struct custom_operations operations={
  .identifier="masc.endpoint_process_gate.v1", .finalize=finalize_handle,
  .compare=custom_compare_default, .hash=custom_hash_default,
  .serialize=custom_serialize_default, .deserialize=custom_deserialize_default,
  .compare_ext=custom_compare_ext_default, .fixed_length=custom_fixed_length_default
};
static value error_option(int error) {
  CAMLparam0();CAMLlocal2(value_,some);
  if (!error) CAMLreturn(Val_none);
  value_=caml_unix_error_of_code(error);some=caml_alloc_small(1,0);Field(some,0)=value_;
  CAMLreturn(some);
}
static value pair_result(int code,int error) {
  CAMLparam0();CAMLlocal2(result,err);
  err=error_option(error);result=caml_alloc_tuple(2);Field(result,0)=Val_int(code);Field(result,1)=err;
  CAMLreturn(result);
}
#ifdef __linux__
struct packet { uint32_t kind; uint32_t stage; int32_t error; };
static void free_vector(char **vector) {
  if (!vector) return;
  for (size_t i=0;vector[i];i++) free(vector[i]);
  free(vector);
}
static char *copy_string(value input) {
  size_t n=caml_string_length(input);
  char *result=malloc(n+1);
  if (result) {memcpy(result,String_val(input),n);result[n]=0;}
  return result;
}
static char **copy_vector(value input) {
  size_t n=Wosize_val(input);
  if (n>SIZE_MAX/sizeof(char *)-1) return NULL;
  char **result=calloc(n+1,sizeof(char *));
  if (!result) return NULL;
  for (size_t i=0;i<n;i++) if (!(result[i]=copy_string(Field(input,i)))) {free_vector(result);return NULL;}
  return result;
}
static int promote(int fd) {
  int copy=fcntl(fd,F_DUPFD_CLOEXEC,FIRST_SOURCE_FD);
  int saved=errno;close(fd);errno=saved;return copy;
}
static void send_failure_to(int fd,int stage,int error) {
  struct packet message={2,(uint32_t)stage,error};
  ssize_t count;
  do {count=send(fd,&message,sizeof(message),MSG_NOSIGNAL);} while (count<0 && errno==EINTR);
  _exit(127);
}
static void send_failure(int stage,int error) { send_failure_to(CTL_FD,stage,error); }
/* The cloned branch calls only syscall/async-signal-safe libc operations.
   It never allocates, calls OCaml or returns through the OCaml runtime. No
   CLONE_VM/CLONE_FILES/CLONE_SIGHAND sharing and no libc atfork handlers. */
static void child_exec(char *program,char **argv,char **env,uid_t uid,gid_t gid,
                       int input,int output,int errors,int control,int directory) {
  if (dup3(control,CTL_FD,O_CLOEXEC)<0) send_failure_to(control,ST_CHILD_DUP,errno);
  if (dup2(input,0)<0 || dup2(output,1)<0 || dup2(errors,2)<0
      || dup3(directory,CWD_FD,O_CLOEXEC)<0)
    send_failure(ST_CHILD_DUP,errno);
  if (syscall(SYS_close_range,(unsigned int)FIRST_SOURCE_FD,UINT_MAX,0)<0)
    send_failure(ST_CHILD_CLOSE,errno);
  if (setsid()<0) send_failure(ST_CHILD_SESSION,errno);
  if (fchdir(CWD_FD)<0) send_failure(ST_CHILD_CWD,errno);
  close(CWD_FD);
  struct sigaction action;
  memset(&action,0,sizeof(action));action.sa_handler=SIG_DFL;sigemptyset(&action.sa_mask);
  for (int sig=1;sig<NSIG;sig++) {
    if (sig==SIGKILL || sig==SIGSTOP) continue;
    if (sigaction(sig,&action,NULL)<0 && errno!=EINVAL) send_failure(ST_CHILD_SIGNALS,errno);
  }
  if (prctl(PR_SET_KEEPCAPS,0,0,0,0)<0 || prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)<0)
    send_failure(ST_CHILD_CAPS,errno);
  /* Raw credential syscalls avoid libc's multi-thread setxid rendezvous in
     the copy of a multi-threaded parent. All real/effective/saved IDs drop. */
  if (syscall(SYS_setgroups,0,NULL)<0 || syscall(SYS_setresgid,gid,gid,gid)<0
      || syscall(SYS_setresuid,uid,uid,uid)<0)
    send_failure(ST_CHILD_CREDENTIALS,errno);
  struct __user_cap_header_struct header={_LINUX_CAPABILITY_VERSION_3,0};
  struct __user_cap_data_struct capabilities[2];memset(capabilities,0,sizeof(capabilities));
  if (syscall(SYS_capset,&header,capabilities)<0
      || prctl(PR_CAP_AMBIENT,PR_CAP_AMBIENT_CLEAR_ALL,0,0,0)<0)
    send_failure(ST_CHILD_CAPS,errno);
  sigset_t empty;sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK,&empty,NULL)<0) send_failure(ST_CHILD_SIGNALS,errno);
  /* No PDEATHSIG: its owner is the creating pool thread, which may retire.
     Before activation private gate EOF aborts; afterwards owner disconnect
     does not silently cancel an accepted payload. */
  struct packet ready={1,0,0};ssize_t count;
  do {count=send(CTL_FD,&ready,sizeof(ready),MSG_NOSIGNAL);} while (count<0 && errno==EINTR);
  if (count!=(ssize_t)sizeof(ready)) _exit(127);
  char decision;
  do {count=recv(CTL_FD,&decision,1,0);} while (count<0 && errno==EINTR);
  if (count!=1 || decision!='A') _exit(125);
  execve(program,argv,env);
  send_failure(ST_CHILD_EXEC,errno);
}
#endif

CAMLprim value masc_endpoint_gate_linux(value unit) {
  (void)unit;
#ifdef __linux__
  return Val_true;
#else
  return Val_false;
#endif
}
CAMLprim value masc_endpoint_gate_spawn(value input) {
  CAMLparam1(input);CAMLlocal3(raw,result,err);
  raw=caml_alloc_custom(&operations,sizeof(struct handle),0,1);
  struct handle initial={-1,-1};memcpy(Data_custom_val(raw),&initial,sizeof(initial));
  int stage=0,error=0,pidfd=-1,parent_control=-1;
#ifdef __linux__
  int sources[3]={-1,-1,-1},directory=-1,child_control=-1,pair[2]={-1,-1},group=-1;
  char *program=copy_string(Field(input,0)),*cwd=copy_string(Field(input,3));
  char **argv=copy_vector(Field(input,1)),**env=copy_vector(Field(input,2));
  intnat uid_value=Long_val(Field(input,4)),gid_value=Long_val(Field(input,5));
  uid_t uid=(uid_t)uid_value;gid_t gid=(gid_t)gid_value;
  int original[3];for(int i=0;i<3;i++) original[i]=Int_val(Field(Field(input,6),i));
  value group_option=Field(input,7);
  int has_group=Is_block(group_option);
  int original_group=has_group?Int_val(Field(group_option,0)):-1;
  if (!program || !cwd || !argv || !env) {stage=ST_ALLOC;error=ENOMEM;}
  else if (geteuid()!=0 || uid_value<=0 || uid==(uid_t)-1 || gid_value<0 || gid==(gid_t)-1
      || (uintmax_t)uid!=(uintmax_t)uid_value || (uintmax_t)gid!=(uintmax_t)gid_value) {
    stage=ST_CHILD_CREDENTIALS;error=EINVAL;
  }
  if (!error) {
    caml_enter_blocking_section();
    for(int i=0;i<3 && !error;i++) {
      sources[i]=fcntl(original[i],F_DUPFD_CLOEXEC,FIRST_SOURCE_FD);
      if(sources[i]<0){stage=ST_DUP;error=errno;}
    }
    if(!error && has_group) {
      group=fcntl(original_group,F_DUPFD_CLOEXEC,FIRST_SOURCE_FD);
      if(group<0){stage=ST_DUP_GROUP;error=errno;}
    }
    if (!error) {
      int fd=open(cwd,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
      if(fd<0){stage=ST_OPEN;error=errno;}
      else {directory=promote(fd);if(directory<0){stage=ST_OPEN;error=errno;}}
    }
    if(!error && socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0,pair)<0){stage=ST_GATE;error=errno;}
    if(!error) {
      parent_control=promote(pair[0]);pair[0]=-1;
      child_control=promote(pair[1]);pair[1]=-1;
      if(parent_control<0 || child_control<0){stage=ST_GATE;error=errno;}
    }
    sigset_t previous,all;int masked=0;sigfillset(&all);
    if(!error) {
      int rc=pthread_sigmask(SIG_SETMASK,&all,&previous);
      if(rc){stage=ST_MASK;error=rc;}else masked=1;
    }
    if(!error) {
      struct clone_args options;memset(&options,0,sizeof(options));
      options.flags=CLONE_PIDFD;options.pidfd=(uintptr_t)&pidfd;options.exit_signal=SIGCHLD;
      if(group>=0){options.flags|=CLONE_INTO_CGROUP;options.cgroup=(uint64_t)group;}
      long child=syscall(SYS_clone3,&options,sizeof(options));
      if(child==0) child_exec(program,argv,env,uid,gid,sources[0],sources[1],sources[2],child_control,directory);
      if(child<0){stage=ST_CLONE;error=errno;}
    }
    if(masked) {
      int rc=pthread_sigmask(SIG_SETMASK,&previous,NULL);
      if(rc && !error){stage=ST_MASK;error=rc;}
    }
    for(int i=0;i<3;i++) if(sources[i]>=0) close(sources[i]);
    if(directory>=0) close(directory);
    if(group>=0) close(group);
    if(child_control>=0) close(child_control);
    if(pair[0]>=0) close(pair[0]);
    if(pair[1]>=0) close(pair[1]);
    if(error) {
      /* A rare parent-side failure after clone never releases an unowned
         running payload: the gate was not activated. Reap through the pidfd. */
      if(parent_control>=0) {shutdown(parent_control,SHUT_RDWR);close(parent_control);parent_control=-1;}
      if(pidfd>=0) {
        syscall(SYS_pidfd_send_signal,pidfd,SIGKILL,NULL,0);
        siginfo_t info;int rc;
        do {rc=waitid(P_PIDFD,(id_t)pidfd,&info,WEXITED);} while(rc<0 && errno==EINTR);
        close(pidfd);pidfd=-1;
      }
    }
    caml_leave_blocking_section();
  }
  free(program);free(cwd);free_vector(argv);free_vector(env);
#else
  error=ENOSYS;
#endif
  struct handle final={pidfd,parent_control};memcpy(Data_custom_val(raw),&final,sizeof(final));
  err=error_option(error);result=caml_alloc_tuple(3);
  Field(result,0)=Val_int(stage);Field(result,1)=err;Field(result,2)=raw;
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_gate_control(value raw) {
  CAMLparam1(raw);CAMLlocal3(result,err,packet_stage);
  int kind=0,stage=0,error=0;
#ifdef __linux__
  struct handle *h=Data_custom_val(raw);struct packet packet;
  ssize_t count;
  do {count=recv(h->control,&packet,sizeof(packet),MSG_DONTWAIT|MSG_TRUNC);}while(count<0 && errno==EINTR);
  if(count<0) {if(errno!=EAGAIN && errno!=EWOULDBLOCK){kind=4;error=errno;}}
  else if(count==0) kind=3;
  else if(count!=(ssize_t)sizeof(packet) || (packet.kind!=1 && packet.kind!=2)) kind=5;
  else {kind=(int)packet.kind;stage=(int)packet.stage;error=packet.error;}
#else
  (void)raw;kind=4;error=ENOSYS;
#endif
  err=error_option(error);packet_stage=Val_int(stage);result=caml_alloc_tuple(3);
  Field(result,0)=Val_int(kind);Field(result,1)=packet_stage;Field(result,2)=err;
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_gate_decide(value raw,value activate) {
  CAMLparam2(raw,activate);int error=0;
#ifdef __linux__
  struct handle *h=Data_custom_val(raw);char byte=Bool_val(activate)?'A':'D';ssize_t count;
  do {count=send(h->control,&byte,1,MSG_DONTWAIT|MSG_NOSIGNAL);}while(count<0 && errno==EINTR);
  if(count!=1) error=count<0?errno:EIO;
#else
  error=ENOSYS;
#endif
  CAMLreturn(pair_result(0,error));
}
CAMLprim value masc_endpoint_gate_signal(value raw,value kill_) {
  CAMLparam2(raw,kill_);int error=0;
#ifdef __linux__
  struct handle *h=Data_custom_val(raw);
  if(syscall(SYS_pidfd_send_signal,h->pidfd,Bool_val(kill_)?SIGKILL:SIGTERM,NULL,0)<0) error=errno;
#else
  error=ENOSYS;
#endif
  CAMLreturn(error_option(error));
}
CAMLprim value masc_endpoint_gate_wait(value raw) {
  CAMLparam1(raw);CAMLlocal2(result,err);int kind=0,status=0,error=0;
#ifdef __linux__
  struct handle *h=Data_custom_val(raw);siginfo_t info;memset(&info,0,sizeof(info));int rc;
  do {rc=waitid(P_PIDFD,(id_t)h->pidfd,&info,WEXITED|WNOHANG);}while(rc<0 && errno==EINTR);
  if(rc<0) error=errno;
  else if(info.si_pid) {
    if(info.si_code==CLD_EXITED){kind=1;status=info.si_status;}
    else if(info.si_code==CLD_KILLED || info.si_code==CLD_DUMPED){kind=2;status=info.si_status;}
    else {kind=3;error=EPROTO;}
  }
#else
  error=ENOSYS;
#endif
  err=error_option(error);result=caml_alloc_tuple(3);
  Field(result,0)=Val_int(kind);Field(result,1)=Val_int(status);Field(result,2)=err;
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_gate_watch(value raw,value exit_) {
  CAMLparam2(raw,exit_);int fd=-1,error=0;
  struct handle *h=Data_custom_val(raw);fd=fcntl(Bool_val(exit_)?h->pidfd:h->control,F_DUPFD_CLOEXEC,0);
  if(fd<0) error=errno;
  CAMLreturn(pair_result(fd,error));
}
CAMLprim value masc_endpoint_gate_close(value raw) {
  CAMLparam1(raw);int error=0;struct handle *h=Data_custom_val(raw);
#ifdef __linux__
  if(h->control>=0) shutdown(h->control,SHUT_RDWR);
#endif
  int control=h->control,pidfd=h->pidfd;h->control=-1;h->pidfd=-1;
  if(control>=0 && close(control)<0) error=errno;
  if(pidfd>=0 && close(pidfd)<0 && !error) error=errno;
  CAMLreturn(error_option(error));
}
