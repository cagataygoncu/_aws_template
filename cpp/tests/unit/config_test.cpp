// The config object as shipped: a broken services/*.json fails the build.
// Mirrors tests/unit/test_config.py in the Python layer. ctest runs it from the
// project root, where container_config.env and services/ are.
#include "../../src/config.hpp"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
    if (!ok) {
        std::cerr << "FAIL: " << what << "\n";
        ++failures;
    }
}

bool throws_with(void (*body)(), const std::string& text) {
    try {
        body();
    } catch (const std::runtime_error& error) {
        return std::string(error.what()).find(text) != std::string::npos;
    }
    return false;
}

}  // namespace

int main() {
    // The shipped config object resolves; both values from container_config.env.
    unsetenv("CONFIG_KEY");
    unsetenv("CONFIG_BLOCK");
    check(!config::load_config(true).settings.empty(), "the shipped config object resolves");

    const auto data = nlohmann::json::parse(
        R"({"profiles": {"p": {"A": 1, "B": 1}}, "blk": {"PROFILE": "p", "B": 2}})");
    const auto settings = config::resolve_block(data, "blk");
    check(settings["A"] == 1 && settings["B"] == 2, "a block's keys win over its profile's");

    check(throws_with([] { config::resolve_block(nlohmann::json::object(), "blk"); }, "no block"),
          "a missing block fails");
    check(throws_with(
              [] {
                  config::resolve_block(nlohmann::json::parse(R"({"blk": {"PROFILE": "nope"}})"),
                                        "blk");
              },
              "names profile"),
          "a missing profile fails");
    check(throws_with(
              [] {
                  config::check_credentials(nlohmann::json::parse(R"({"X_CREDENTIAL": "cred_9"})"),
                                            {{"cred_1", {}}});
              },
              "X_CREDENTIAL=cred_9"),
          "an unknown credential id fails");

    if (failures == 0) {
        std::cout << "config tests passed\n";
    }
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
