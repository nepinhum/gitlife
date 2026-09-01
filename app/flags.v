module app

const valued = ['something']

struct Flags {

}

// TODO : parse args into Flags struct
fn parse(args []string) !Flags {
	mut f := Flags{}

	return f
}

fn check_date(s string) !string {
	if s.len != 10 || s[4] != `-` || s[7] != `-` {
		return error("'${s}' is not a date; use YYYY-MM-DD")
	}
	return s
}
