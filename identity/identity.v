module identity

// norm_email folds an email for matching. Domains are case insensitive by RFC
// and every forge in scope treats the local part case insensitively too, so the
// whole string folds. The observed spelling is stored unchanged alongside it.
pub fn norm_email(s string) string {
	return s.trim_space().to_lower()
}

// norm_name does not fold case. A name is a chosen display string; folding it
// would silently merge two people who picked the same letters.
pub fn norm_name(s string) string {
	return s.trim_space()
}
