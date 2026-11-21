#include "config.hpp"

#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace config {

namespace {

const std::string kCredentialSuffix = "_CREDENTIAL";
const std::string kEnvFile = "container_config.env";

bool ends_with(const std::string& text, const std::string& suffix) {
    return text.size() >= suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string trim(const std::string& text) {
    const auto first = text.find_first_not_of(" \t\r");
    if (first == std::string::npos) {
        return "";
    }
    return text.substr(first, text.find_last_not_of(" \t\r") - first + 1);
}

// An environment variable; for a local run, else container_config.env's.
std::string setting(const std::string& name, bool local) {
    const char* value = std::getenv(name.c_str());
    if ((value && *value) || !local) {
        return value ? value : "";
    }
    std::ifstream file(kEnvFile);
    std::string line;
    while (std::getline(file, line)) {
        if (line.compare(0, name.size() + 1, name + "=") == 0) {
            return trim(line.substr(name.size() + 1));
        }
    }
    return "";
}

std::string basename_of(const std::string& path) {
    const auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string read_config_object(bool local) {
    const std::string key = setting("CONFIG_KEY", local);
    if (!local) {
        throw std::runtime_error(
            "online mode reads s3://CONFIG_BUCKET/CONFIG_KEY, which needs the AWS SDK for "
            "C++ - see src/config.hpp");
    }
    if (key.empty()) {
        throw std::runtime_error("CONFIG_KEY is not set");
    }
    const std::string path = "services/" + basename_of(key);
    std::ifstream file(path);
    if (!file) {
        throw std::runtime_error("cannot read " + path);
    }
    std::stringstream content;
    content << file.rdbuf();
    return content.str();
}

}  // namespace

nlohmann::json resolve_block(const nlohmann::json& data, const std::string& block_name) {
    if (!data.contains(block_name)) {
        throw std::runtime_error("the config object has no block \"" + block_name + "\"");
    }
    const nlohmann::json& block = data.at(block_name);
    if (!block.is_object()) {
        throw std::runtime_error("block \"" + block_name + "\" is not a JSON object");
    }
    const std::string profile_name = block.value("PROFILE", "");
    if (profile_name.empty()) {
        return block;
    }
    const nlohmann::json profiles = data.value("profiles", nlohmann::json::object());
    if (!profiles.contains(profile_name) || !profiles.at(profile_name).is_object()) {
        throw std::runtime_error("block \"" + block_name + "\" names profile \"" + profile_name +
                                 "\", which the config object does not have");
    }
    nlohmann::json settings = profiles.at(profile_name);
    settings.update(block);
    return settings;
}

void check_credentials(const nlohmann::json& settings,
                       const std::map<std::string, Credential>& credentials) {
    std::vector<std::string> missing;
    for (auto it = settings.begin(); it != settings.end(); ++it) {
        if (!ends_with(it.key(), kCredentialSuffix)) {
            continue;
        }
        const std::string id = it->is_string() ? it->get<std::string>() : it->dump();
        if (credentials.find(id) == credentials.end()) {
            missing.push_back(it.key() + "=" + id);
        }
    }
    if (!missing.empty()) {
        std::string list;
        for (const auto& entry : missing) {
            list += (list.empty() ? "" : ", ") + entry;
        }
        throw std::runtime_error("credential ids not in the secret: " + list);
    }
}

Config load_config(bool local) {
    Config config;
    config.block = setting("CONFIG_BLOCK", local);
    if (config.block.empty()) {
        throw std::runtime_error("CONFIG_BLOCK is not set");
    }
    config.settings = resolve_block(nlohmann::json::parse(read_config_object(local)), config.block);
    return config;
}

const Config& get_config(bool local) {
    static const Config config = load_config(local);
    return config;
}

}  // namespace config
