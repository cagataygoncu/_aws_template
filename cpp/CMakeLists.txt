cmake_minimum_required(VERSION 3.13)
project({{PROJECT_NAME}} CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wfatal-errors")

# The target is named `main` because that is what the Dockerfiles copy out of
# the builder and run: COPY --from=builder /app/build/main. Rename both
# together if you rename it here.
add_executable(main ./src/main.cpp)

# libcrypto for the SHA-256 in f1(). Both Dockerfile stages already carry it -
# libssl-dev in the builder, libssl3 in the final image.
find_package(OpenSSL REQUIRED)
target_link_libraries(main PRIVATE OpenSSL::Crypto)

# Add what this service actually needs beside it, for example:
#
#   find_package(AWSSDK REQUIRED COMPONENTS secretsmanager s3)
#   target_link_libraries(main PRIVATE ${AWSSDK_LINK_LIBRARIES})
#
# Anything added here has to be installed in BOTH Dockerfile stages: the
# -dev package in the builder, the runtime library in the final image.
