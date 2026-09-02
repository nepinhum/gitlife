module proc

import os
import time

// max_stderr bounds retained diagnostics. Errors are for humans, not for dumps.
const max_stderr = 8192

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
	mut p := os.new_process(cmd.exe)
	p.set_args(cmd.args)
	if cmd.cwd != '' {
		p.set_work_folder(cmd.cwd)
	}
	if cmd.env.len > 0 {
		p.set_environment(cmd.env)
	}
	p.set_redirect_stdio()
	p.run()
	if !p.is_alive() && p.code != 0 && p.status == .not_started {
		return error("failed to start '${cmd.exe}'")
	}

	mut out := []string{}
	mut errs := []string{}
	mut errs_len := 0
	for p.is_alive() {
		mut moved := false
		if chunk := p.pipe_read(.stdout) {
			out << chunk
			moved = true
		}
		if chunk := p.pipe_read(.stderr) {
			// Past the cap the data is still read, just not kept. Draining is what
			// keeps the child running.
			if errs_len < max_stderr {
				errs << chunk
				errs_len += chunk.len
			}
			moved = true
		}
		if !moved {
			time.sleep(time.millisecond)
		}
	}
	// The child is gone; whatever it left in the pipes is still ours to take.
	for {
		chunk := p.pipe_read(.stdout) or { break }
		out << chunk
	}
	for {
		chunk := p.pipe_read(.stderr) or { break }
		if errs_len < max_stderr {
			errs << chunk
			errs_len += chunk.len
		}
	}
	p.wait()
	code := p.code
	p.close()
	return Result{
		exit_code: code
		stdout: out.join('')
		stderr: truncate(errs.join(''))
	}
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
