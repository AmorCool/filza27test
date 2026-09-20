//! Shared FFI utilities.

use std::ffi::{c_char, CStr, CString};

/// Convert an optional C string to an owned Rust string, returning `default`
/// for null or invalid input.
pub fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_owned();
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .unwrap_or(default)
        .to_owned()
}

/// Heap-allocate a C string from any `Display`-able value. The caller is
/// responsible for freeing it with `string_free`.
pub fn cstr(s: impl std::fmt::Display) -> *mut c_char {
    let s = format!("{s}");
    CString::new(s)
        .unwrap_or_else(|_| CString::new("(null bytes in string)").unwrap())
        .into_raw()
}

/// Free a `*mut c_char` returned by this library.
///
/// # Safety
/// `p` must be null or a pointer previously returned by `cstr`.
pub unsafe fn string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
