module main

// Substituted at bootstrap from language_version, the same value that picks
// the golang:<version>-bookworm image - so the module and the toolchain it is
// built with cannot drift apart. Override per project:
//   make new golang my_project LANGUAGE_VERSION=1.26
go {{LANGUAGE_VERSION}}
