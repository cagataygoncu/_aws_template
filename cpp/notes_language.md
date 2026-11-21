## C++

The C++ tools, and how to run, test and debug. Tool versions are in
`mise.toml`.

### Tools

`mise.toml` installs cmake, ninja, clang-format, cfn-lint and uv. The
compiler is the system one: Xcode command-line tools on a Mac
(`xcode-select --install`), `build-essential` in the containers. Libraries
such as OpenSSL come from `system_packages_build.txt` in the containers, and
from Homebrew on a Mac.

### Run

```zsh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
MODE=local ./build/main
```

### Test

```zsh
cmake -S . -B build -G Ninja && cmake --build build
ctest --test-dir build --output-on-failure      # tests/unit, from the project root
make test                                       # as the pipeline: in the base image, JUnit to reports/
make lint                                       # clang-format --dry-run, cfn-lint
```

Add a test as an executable in `CMakeLists.txt`, with `add_test()`.

### Debug (F5)

| Configuration | Starts |
|---|---|
| Run main | builds with the *CMake: build* task, then runs `build/main` under gdb |

It sets `MODE=local`. gdb is in the devcontainer, not on a Mac: debug C++ in
the devcontainer. The binary name comes from `add_executable()` in
`CMakeLists.txt`; rename both together.

### Devcontainer

The dev image is Debian (the release in `mise.toml`) plus both package
lists, gdb and the C++ toolchain. This is the main place to build and debug
C++ that links against Linux libraries.

There is no lambda target: nothing builds the `bootstrap` executable a
custom-runtime Lambda needs.
