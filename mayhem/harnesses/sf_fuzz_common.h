// Shared helpers for the Stockfish fuzz harnesses (mayhem/harnesses/).
#ifndef SF_FUZZ_COMMON_H
#define SF_FUZZ_COMMON_H

#include <iostream>
#include <sstream>
#include <string>

#include "engine.h"
#include "ucioption.h"

namespace sf_fuzz {

// Set a UCI option through the engine's own `setoption` parser, so the option callbacks run exactly
// as they do for a GUI.
inline void setoption(Stockfish::Engine& e, const std::string& name, const std::string& value) {
    std::istringstream is("name " + name + " value " + value);
    e.get_options().setoption(is);
}

// The engine reports through callbacks; a search with an unset std::function would abort, so give
// each one a no-op. Engine output is not part of what we check, so it is discarded.
inline void quiet_listeners(Stockfish::Engine& e) {
    e.set_on_update_no_moves([](const auto&) {});
    e.set_on_update_full([](const auto&) {});
    e.set_on_iter([](const auto&) {});
    e.set_on_bestmove([](auto, auto) {});
    e.set_on_start([]() {});
    e.set_on_verify_network([](auto) {});
    e.get_options().add_info_listener([](const auto&) {});
}

inline void discard_stdout() { std::cout.rdbuf(nullptr); }

}  // namespace sf_fuzz

#endif
