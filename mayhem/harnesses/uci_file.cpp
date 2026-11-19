// File-input (AFL) target: the UCI command stream, as Stockfish reads it from stdin.
//
// Usage: uci_afl <file>. The file's lines are fed to UCIEngine::loop() exactly like stdin (EOF is
// `quit`). This is a whole-process target, not libFuzzer, because the engine calls exit() on
// commands it treats as fatal (an invalid `position`, see UCIEngine::terminate_on_critical_error);
// every execution is a fresh process, so no state survives between inputs.
//
// Lines go through an allow-list on their first token, tokenized the way loop() tokenizes them
// (`is >> token`), so the filter sees exactly what the engine sees:
//  - dropped: `bench`, `speedtest`, `export_net` (long-running benchmarks / a file writer) and
//    `go ... perft` (perft is exponential in the depth by definition);
//  - `setoption` is dropped for the options that open or create files given by name
//    (`Debug Log File`, `EvalFile`, `SyzygyPath`: the file formats have their own targets) and for
//    `Hash` / `Threads` (a resource size: up to 32 TB of hash / 1024 threads, and more than one
//    thread makes the search nondeterministic). Option names compare case-insensitively, as in
//    OptionsMap.
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

#include "attacks.h"
#include "misc.h"
#include "tune.h"
#include "uci.h"

using namespace Stockfish;

static std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
    return s;
}

static bool allowed(const std::string& line) {
    std::istringstream is(line);
    std::string        token;
    is >> token;
    if (token == "bench" || token == "speedtest" || token == "export_net")
        return false;
    if (token == "go")
    {
        while (is >> token)
            if (token == "perft")
                return false;
        return true;
    }
    if (token == "setoption")
    {
        // Same parse as OptionsMap::setoption: "name" then the name tokens up to "value".
        std::string name;
        is >> token;
        while (is >> token && token != "value")
            name += (name.empty() ? "" : " ") + token;
        name = lower(name);
        return name != "debug log file" && name != "evalfile" && name != "syzygypath"
            && name != "hash" && name != "threads";
    }
    return true;
}

int main(int argc, char* argv[]) {
    if (argc < 2)
    {
        std::cerr << "usage: " << argv[0] << " <uci-commands-file>" << std::endl;
        return 2;
    }
    std::ifstream file(argv[1], std::ios::binary);
    if (!file)
    {
        std::cerr << "cannot open " << argv[1] << std::endl;
        return 2;
    }
    std::string filtered, line;
    while (std::getline(file, line))
        if (allowed(line))
            filtered += line + "\n";

    std::istringstream commands(filtered);
    std::cin.rdbuf(commands.rdbuf());
    std::cout.rdbuf(nullptr);  // engine output is not checked; discard it

    Attacks::init();
    char* args[] = {argv[0], nullptr};
    auto  uci    = std::make_unique<UCIEngine>(CommandLine(1, args));
    Tune::init(uci->engine_options());
    uci->loop();
    return 0;
}
