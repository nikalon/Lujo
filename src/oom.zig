// World's most sophisticated error handler
pub inline fn handleOutOfMemoryError() noreturn {
    @panic("Out of memory. Buy more RAM.");
}
