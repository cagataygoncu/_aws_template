// The service's configuration: one secret, one config object, one block.
//
// container_config.env names all three:
//
//   AWS_SECRET_NAME   the Secrets Manager secret - credentials and API keys only:
//                     {"credentials": {"<id>": {"username": ..., "password": ...}},
//                      "api_keys": {"<id>": "<key>"}}
//   CONFIG_BUCKET     the config object in S3: every other setting, as JSON
//   CONFIG_KEY
//   CONFIG_BLOCK      the block of the config object this deployment runs
//
// A block may name a PROFILE from the object's "profiles"; the block's own keys
// win over its profile's. A setting ending in _CREDENTIAL holds a credential
// id, looked up in the secret.
//
// With MODE=local nothing is read from AWS: the config object is the local
// copy, services/<basename of CONFIG_KEY>, and there are no credentials or API
// keys. CONFIG_KEY and CONFIG_BLOCK a local run does not have are read from
// container_config.env. Mirrors src/config.py in the Python layer.
//
// Online mode needs the AWS SDK for C++ for S3 and Secrets Manager, which this
// layer does not ship: load_config(false) says so. Add it in CMakeLists.txt
// and read the two in config.cpp's read_config_object() and read_secret().
#pragma once

#include <map>
#include <nlohmann/json.hpp>
#include <string>

namespace config {

struct Credential {
    std::string username;
    std::string password;
};

struct Config {
    std::string block;
    nlohmann::json settings = nlohmann::json::object();
    std::map<std::string, Credential> credentials;
    std::map<std::string, std::string> api_keys;
};

// The block's settings, on top of its PROFILE's. Throws std::runtime_error.
nlohmann::json resolve_block(const nlohmann::json& data, const std::string& block_name);

// Throws when a *_CREDENTIAL setting names a credential the secret lacks.
void check_credentials(const nlohmann::json& settings,
                       const std::map<std::string, Credential>& credentials);

// Reads the configuration. Throws std::runtime_error.
Config load_config(bool local);

// The configuration, read once at the first call; a change takes a restart.
const Config& get_config(bool local);

}  // namespace config
