// libFuzzer harness: a deterministic search on a fuzzed position, through the public Engine API.
//
// Input: byte 0 picks search options, the rest of line 1 is a FEN, and the following lines are
// whitespace-separated moves in UCI notation (what `position fen <FEN> moves <...>` passes to
// Engine::set_position). The engine validates the FEN and moves itself; an input it rejects is
// rejected (-1). An accepted position is searched to a fixed node count with one thread, so the
// search (movegen, movepick, history updates, qsearch, NNUE evaluation, TT) is deterministic.
//
// State kept across inputs on purpose: one Engine (constructing it loads the 138 MB embedded
// network). Each input resets every option it can change and calls search_clear(), which clears
// the transposition table and all histories, so a result depends only on the input.
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

#include "attacks.h"
#include "engine.h"
#include "misc.h"
#include "search.h"
#include "sf_fuzz_common.h"

using namespace Stockfish;

extern "C" int LLVMFuzzerInitialize(int*, char***);
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

static Engine* engine;

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    sf_fuzz::discard_stdout();
    Attacks::init();
    engine = new Engine();
    sf_fuzz::quiet_listeners(*engine);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1)
        return -1;
    const uint8_t cfg = data[0];
    std::string   text(reinterpret_cast<const char*>(data + 1), size - 1);

    std::istringstream in(text);
    std::string        fen, line, tok;
    std::getline(in, fen);
    std::vector<std::string> moves;
    while (std::getline(in, line))
    {
        std::istringstream ls(line);
        while (ls >> tok)
            moves.push_back(tok);
    }

    engine->wait_for_search_finished();
    sf_fuzz::setoption(*engine, "UCI_Chess960", (cfg & 1) ? "true" : "false");
    sf_fuzz::setoption(*engine, "MultiPV", std::to_string(1 + ((cfg >> 1) & 3)));
    sf_fuzz::setoption(*engine, "UCI_LimitStrength", (cfg & 8) ? "true" : "false");
    sf_fuzz::setoption(*engine, "UCI_Elo", std::to_string(1320 + 100 * ((cfg >> 4) & 7)));
    sf_fuzz::setoption(*engine, "Skill Level", (cfg & 0x80) ? "5" : "20");
    engine->search_clear();

    if (engine->set_position(fen, moves).has_value())
        return -1;

    Search::LimitsType limits;
    limits.startTime = now();
    limits.nodes     = 4000;
    engine->go(limits);
    engine->wait_for_search_finished();
    return 0;
}
