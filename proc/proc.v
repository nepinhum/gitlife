module proc

import os

#include <poll.h>

#include <fcntl.h>

#include <unistd.h>

#include <sys/wait.h>

// The spawn declarations are untyped on purpose and spawn.h is not included:
// vlib's own os module declares these with void* and including the real header
// makes the two disagree. The pointer is a pointer either way.
//
// Actions stands in for posix_spawn_file_actions_t which _init fills in. 128
// bytes clears glibc's 80 and musl's 40 and u64 gives it the alignment a
// struct of ints and pointers wants.
struct Actions {
	words [16]u64
}

struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.posix_spawn_file_actions_init(voidptr) int

fn C.posix_spawn_file_actions_destroy(voidptr) int

fn C.posix_spawn_file_actions_adddup2(voidptr, int, int) int

fn C.posix_spawn_file_actions_addclose(voidptr, int) int

fn C.posix_spawn_file_actions_addopen(voidptr, int, &char, int, u32) int

fn C.posix_spawn_file_actions_addchdir_np(voidptr, &char) int

fn C.posix_spawn(&int, &char, voidptr, voidptr, &&char, &&char) int

fn C.pipe(&int) int

fn C.read(int, voidptr, usize) int

fn C.close(int) int

fn C.poll(&C.pollfd, u64, int) int

fn C.waitpid(int, &int, int) int

// max_stderr bounds retained diagnostics. Errors are for humans, not for dumps.
const max_stderr = 8192

// read_size is one pipe buffer which is what a ready pipe holds at most.
const read_size = 65536

pub struct Cmd {
pub:
	exe  string // absolute path, from find()
	args []string
	cwd  string // empty means the current directory
	// env, when non empty, replaces the child's environment entirely. Build it
	// with child_env: a partial map silently strips PATH and HOME.
	env map[string]string
}

pub struct Result {
pub:
	exit_code int
	stdout    string
	stderr    string
}

// child is a started process and the two pipes it writes to.
struct Child {
	pid    int
	stdout int
	stderr int
}

// find resolves an executable in PATH once. Callers hold the path instead of
// paying for a PATH scan per invocation.
pub fn find(name string) !string {
	return os.find_abs_path_of_executable(name) or {
		error("required executable '${name}' was not found in PATH")
	}
}

// run executes cmd to completion and returns its streams and exit code.
// A nonzero exit code is not an error here; the caller decides what it means.
pub fn run(cmd Cmd) !Result {
	child := start(cmd)!
	out, errs := drain(child)
	return Result{
		exit_code: wait_for(child.pid)
		stdout: out
		stderr: truncate(errs)
	}
}

// start hands the child to libc through posix_spawn, making this
// safe to call from several threads at once.
//
// Forking doesn't survive the parallel sync. A fork copies the calling thread
// alone, locks and all so a child that allocates before it reaches exec can
// wait forever on a lock another thread held at the moment of the fork. That is
// what 'gitlife sync --jobs 8' hit, hanging about half the time, forked but
// never exec'd. posix_spawn runs no code of ours in the child.
fn start(cmd Cmd) !Child {
	mut out := [2]int{}
	mut errs := [2]int{}
	if C.pipe(&out[0]) != 0 {
		return error("failed to start '${cmd.exe}': no pipe for its output")
	}
	if C.pipe(&errs[0]) != 0 {
		C.close(out[0])
		C.close(out[1])
		return error("failed to start '${cmd.exe}': no pipe for its output")
	}

	mut actions := Actions{}
	C.posix_spawn_file_actions_init(&actions)
	// Nothing here ever writes to a child and a child holding a terminal can
	// sit waiting on input that is never coming.
	mut bad := C.posix_spawn_file_actions_addopen(&actions, 0, c'/dev/null', C.O_RDONLY, 0)
	bad += C.posix_spawn_file_actions_adddup2(&actions, out[1], 1)
	bad += C.posix_spawn_file_actions_adddup2(&actions, errs[1], 2)
	bad += C.posix_spawn_file_actions_addclose(&actions, out[0])
	bad += C.posix_spawn_file_actions_addclose(&actions, out[1])
	bad += C.posix_spawn_file_actions_addclose(&actions, errs[0])
	bad += C.posix_spawn_file_actions_addclose(&actions, errs[1])
	if cmd.cwd != '' {
		// Unchecked, this is a child running somewhere else entirely and
		// answering about the wrong repository.
		bad += C.posix_spawn_file_actions_addchdir_np(&actions, &char(cmd.cwd.str))
	}
	if bad != 0 {
		C.posix_spawn_file_actions_destroy(&actions)
		C.close(out[0])
		C.close(out[1])
		C.close(errs[0])
		C.close(errs[1])
		return error("failed to start '${cmd.exe}': its file descriptors could not be arranged")
	}

	// argv and envp are read by libc during the call, the V strings behind
	// them are held in scope until it returns.
	mut words := [cmd.exe]
	words << cmd.args
	mut argv := []&char{cap: words.len + 1}
	for word in words {
		argv << &char(word.str)
	}
	argv << &char(unsafe { nil })

	environment := if cmd.env.len > 0 { cmd.env } else { os.environ() }
	mut pairs := []string{cap: environment.len}
	for name, value in environment {
		pairs << '${name}=${value}'
	}
	mut envp := []&char{cap: pairs.len + 1}
	for pair in pairs {
		envp << &char(pair.str)
	}
	envp << &char(unsafe { nil })

	pid := 0
	code := C.posix_spawn(&pid, &char(cmd.exe.str), &actions, C.NULL, argv.data, envp.data)
	C.posix_spawn_file_actions_destroy(&actions)
	// The write ends belong to the child now. Holding them here would keep the
	// pipes open after it exits and the read below would never end.
	C.close(out[1])
	C.close(errs[1])
	if code != 0 {
		C.close(out[0])
		C.close(errs[0])
		return error("failed to start '${cmd.exe}'")
	}
	return Child{
		pid: pid
		stdout: out[0]
		stderr: errs[0]
	}
}

// drain reads both pipes until the child closes them. Both, in one loop:
// reading one to the end deadlocks as soon as the child fills the other which
// git does on a large clone.
fn drain(child Child) (string, string) {
	mut out := []u8{}
	mut errs := []u8{}
	mut errs_len := 0
	mut buf := []u8{len: read_size}
	mut fds := [child.stdout, child.stderr]!
	mut open := 2

	for open > 0 {
		mut set := [2]C.pollfd{}
		set[0] = C.pollfd{
			fd: fds[0]
			events: C.POLLIN
		}
		set[1] = C.pollfd{
			fd: fds[1]
			events: C.POLLIN
		}
		// The garbage collector stops the world with a signal, so an interrupted
		// poll is ordinary here and means nothing more than 'ask again'.
		if C.poll(&set[0], 2, -1) < 0 {
			if C.errno == C.EINTR {
				continue
			}
			break
		}
		for i in 0 .. 2 {
			if fds[i] < 0 || set[i].revents == 0 {
				continue
			}
			n := C.read(fds[i], buf.data, read_size)
			if n <= 0 {
				C.close(fds[i])
				fds[i] = -1
				open--
				continue
			}
			if i == 0 {
				unsafe { out.push_many(buf.data, n) }
				continue
			}
			// Past the cap the data is still read, just not kept. Draining is
			// what keeps the child running.
			if errs_len < max_stderr {
				unsafe { errs.push_many(buf.data, n) }
			}
			errs_len += n
		}
	}
	for fd in fds {
		if fd >= 0 {
			C.close(fd)
		}
	}
	return out.bytestr(), errs.bytestr()
}

// wait_for reaps the child and returns the exit code the shell would report:
// the status for an ordinary exit, 128 plus the signal for a killed one.
fn wait_for(pid int) int {
	status := 0
	for C.waitpid(pid, &status, 0) < 0 {
		if C.errno != C.EINTR {
			return -1
		}
	}
	if status & 0x7f == 0 {
		return (status >> 8) & 0xff
	}
	return 128 + (status & 0x7f)
}

// check runs cmd and fails unless it exited zero.
pub fn check(cmd Cmd) !Result {
	r := run(cmd)!
	if r.exit_code != 0 {
		return error("'${os.file_name(cmd.exe)} ${cmd.args.join(' ')}' exited ${r.exit_code}: ${r.stderr.trim_space()}")
	}
	return r
}

pub fn child_env(remove []string, add map[string]string) map[string]string {
	mut env := os.environ()
	for name in remove {
		env.delete(name)
	}
	for name, value in add {
		env[name] = value
	}
	return env
}

fn truncate(s string) string {
	if s.len <= max_stderr {
		return s
	}
	return s[..max_stderr] + '\n.. (truncated)'
}
