// Leaks are not the bug class this integration fuzzes for (SPEC §6.2 item 15): turn LeakSanitizer
// off at build time for every ASan binary. ASan and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }
