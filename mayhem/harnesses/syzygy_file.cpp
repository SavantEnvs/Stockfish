// File-input (AFL) target: Syzygy tablebase files, as loaded through `setoption name SyzygyPath`
// and probed by a search.
//
// Usage: syzygy_afl <file>. Input layout:
//   byte 0      bits 0-2: material table (KQvK, KRvK, KPvK, KBNvK, KRvKP, mod 5)
//               bit 3: UCI_LimitStrength on; bit 4: Syzygy50MoveRule off
//   bytes 1-4   little-endian length N of the WDL (.rtbw) file
//   N bytes     the .rtbw file
//   the rest    the .rtbz (DTZ) file; none is written when the rest is empty
// The files are written to a fresh directory under $TMPDIR, SyzygyPath is pointed at it (which runs
// Tablebases::init's file discovery), and the engine searches a position of that material for a
// fixed node count: the root probe (root_probe / root_probe_wdl) and in-search probe_wdl/probe_dtz
// map and decode the files. This is a whole-process target, not libFuzzer, because the tablebase
// reader calls exit() on a file it detects as corrupt; every execution is a fresh process.
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

#include "attacks.h"
#include "engine.h"
#include "misc.h"
#include "search.h"
#include "sf_fuzz_common.h"

using namespace Stockfish;

namespace {
struct Table {
    const char* name;
    const char* fen;
};
const Table tables[] = {
  {"KQvK", "8/8/8/8/8/4k3/8/4K2Q w - - 0 1"},  {"KRvK", "8/8/8/8/8/4k3/8/4K2R w - - 0 1"},
  {"KPvK", "8/8/8/8/8/4k3/4P3/4K3 w - - 0 1"}, {"KBNvK", "8/8/8/8/8/4k3/8/3BKN2 w - - 0 1"},
  {"KRvKP", "8/8/8/8/4p3/4k3/8/R3K3 w - - 0 1"},
};

void write_file(const std::string& path, const char* p, size_t n) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f || (n && fwrite(p, 1, n, f) != n))
    {
        perror(path.c_str());
        abort();
    }
    fclose(f);
}

// The reader exit()s on a corrupt file; remove the scratch files on that path too.
std::string scratch_dir, scratch_wdl, scratch_dtz;
void        remove_scratch() {
    unlink(scratch_wdl.c_str());
    unlink(scratch_dtz.c_str());
    rmdir(scratch_dir.c_str());
}
}  // namespace

int main(int argc, char* argv[]) {
    if (argc < 2)
    {
        std::cerr << "usage: " << argv[0] << " <file>" << std::endl;
        return 2;
    }
    std::ifstream     in(argv[1], std::ios::binary);
    std::vector<char> buf((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (buf.size() < 5)
        return 0;

    const uint8_t cfg = uint8_t(buf[0]);
    const Table&  t   = tables[(cfg & 7) % 5];
    size_t        n   = size_t(uint8_t(buf[1])) | size_t(uint8_t(buf[2])) << 8
             | size_t(uint8_t(buf[3])) << 16 | size_t(uint8_t(buf[4])) << 24;
    n = std::min(n, buf.size() - 5);

    const char* tmp = getenv("TMPDIR");
    std::string dir = std::string(tmp && *tmp ? tmp : "/tmp") + "/sf-syzygy-XXXXXX";
    if (!mkdtemp(dir.data()))
    {
        perror("mkdtemp");
        abort();
    }
    const std::string wdl = dir + "/" + t.name + ".rtbw", dtz = dir + "/" + t.name + ".rtbz";
    scratch_dir = dir, scratch_wdl = wdl, scratch_dtz = dtz;
    std::atexit(remove_scratch);
    write_file(wdl, buf.data() + 5, n);
    const size_t rest = buf.size() - 5 - n;
    if (rest)
        write_file(dtz, buf.data() + 5 + n, rest);

    sf_fuzz::discard_stdout();
    Attacks::init();
    int status = 0;
    {
        Engine engine;
        sf_fuzz::quiet_listeners(engine);
        sf_fuzz::setoption(engine, "UCI_LimitStrength", (cfg & 8) ? "true" : "false");
        sf_fuzz::setoption(engine, "Syzygy50MoveRule", (cfg & 16) ? "false" : "true");
        sf_fuzz::setoption(engine, "SyzygyPath", dir);
        if (engine.set_position(t.fen, {}).has_value())
            status = 1;
        else
        {
            Search::LimitsType limits;
            limits.startTime = now();
            limits.nodes     = 2000;
            engine.go(limits);
            engine.wait_for_search_finished();
        }
        sf_fuzz::setoption(engine, "SyzygyPath", "");  // unmap the files before removing them
    }
    return status;  // remove_scratch runs at exit
}
