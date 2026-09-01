module main

import os
import app

fn main() {
	exit(app.run(os.args[1..]))
}
