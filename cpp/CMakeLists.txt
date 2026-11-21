cmake_minimum_required(VERSION 3.14)
project({{PROJECT_NAME}} CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wfatal-errors")

# The target is named `main` because that is what the Dockerfiles copy out of
# the builder and run: COPY --from=builder /app/build/main. Rename both
# together if you rename it here.
add_executable(main ./src/main.cpp ./src/config.cpp)

# nlohmann/json, header-only, for the config object (src/config.hpp). Fetched
# by URL at configure time, so nothing is installed on the Mac or in an image.
include(FetchContent)
FetchContent_Declare(json
    URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d)
FetchContent_MakeAvailable(json)
target_link_libraries(main PRIVATE nlohmann_json::nlohmann_json)

# libcrypto for the SHA-256 in f1(). Both Dockerfile stages already carry it -
# libssl-dev in the builder, libssl3 in the final image.
find_package(OpenSSL REQUIRED)
target_link_libraries(main PRIVATE OpenSSL::Crypto)

# The unit tests: `ctest --test-dir build`, and make test, which writes a JUnit
# report with --output-junit. They run from the project root, where
# container_config.env and services/ are.
# The images build with -DBUILD_TESTS=OFF: their build context has no tests/.
option(BUILD_TESTS "Build the unit tests" ON)
if(BUILD_TESTS)
    enable_testing()
    add_executable(config_test ./tests/unit/config_test.cpp ./src/config.cpp)
    target_link_libraries(config_test PRIVATE nlohmann_json::nlohmann_json)
    add_test(NAME config_test COMMAND config_test WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
endif()

# Add what this service actually needs beside it, for example:
#
#   find_package(AWSSDK REQUIRED COMPONENTS secretsmanager s3)
#   target_link_libraries(main PRIVATE ${AWSSDK_LINK_LIBRARIES})
#
# Anything added here has to be installed in BOTH Dockerfile stages: the
# -dev package in the builder, the runtime library in the final image.
