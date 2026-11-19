// libFuzzer harness: an NNUE network file, as loaded by `setoption name EvalFile value <file>`.
//
// The input is written to a scratch file and handed to Network::load(), the loader the EvalFile
// option runs (Engine::load_network -> Network::load -> load_external): header (version, hash,
// description), the LEB128-compressed feature transformer and the layer stacks.
//
// State kept across inputs on purpose: one Network object (its parameter arrays are ~140 MB).
// load() overwrites every field it reads and a fresh EvalFile is used per input, so whether a file
// loads, and what it loads, depends only on that input. Nothing is evaluated with a loaded net.
#include <unistd.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>

#include "attacks.h"
#include "nnue/network.h"
#include "nnue/nnue_misc.h"
#include "sf_fuzz_common.h"

using namespace Stockfish;

extern "C" int LLVMFuzzerInitialize(int*, char***);
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

static std::unique_ptr<Eval::NNUE::Network> net;
static std::string                          path;

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    sf_fuzz::discard_stdout();
    Attacks::init();
    net = std::make_unique<Eval::NNUE::Network>();
    const char* tmp = getenv("TMPDIR");
    std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/sf-nnue-XXXXXX";
    int fd = mkstemp(tmpl.data());
    if (fd < 0)
    {
        perror("mkstemp");
        abort();
    }
    close(fd);
    path = tmpl;
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f)
        abort();
    if (size && fwrite(data, 1, size, f) != size)
        abort();
    fclose(f);

    Eval::NNUE::EvalFile evalFile{std::nullopt, ""};
    net->load(std::filesystem::path{}, std::filesystem::path(path), evalFile);
    // A file the loader rejects part-way still drove the parser, so keep it in the corpus (0).
    return 0;
}
