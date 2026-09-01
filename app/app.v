module app

import os

const help = r"usage:
	gitlife blablabla
"

fn usage() string {
	return '${build_info()} - a provider-independent history of your work in Git\n\n' + help
}

pub fn run(args []string) int {
	if args.len == 0 || args[0] in ['help', '-h', '--help'] {
		println(usage())
		return 0
	}

	if args[0] in ['version', '--version'] {
		println(build_info())
		return 0
	}

	// TODO : dispatch commands and return exit code
	return 1
}
