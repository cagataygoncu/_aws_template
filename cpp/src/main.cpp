// Mirrors the Python and Go stubs: one processRequest() that every target
// funnels into, so the behaviour is the same however this is deployed.

#include <cctype>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <algorithm>

namespace {

// Mode decides where the service gets the things it depends on. Deployed code
// is online; a local run opts out with MODE=local.
//
// Online is the default so that nothing has to be set on AWS, and forgetting
// to set it locally fails loudly on the first AWS call rather than silently
// running against stub data in production.
enum class Mode { Online, Local };

std::string env_or(const char* name, const std::string& fallback = "") {
    const char* value = std::getenv(name);
    return value ? std::string(value) : fallback;
}

Mode get_mode() {
    std::string mode = env_or("MODE");
    std::transform(mode.begin(), mode.end(), mode.begin(),
                   [](unsigned char c) { return std::tolower(c); });

    if (mode == "local") {
        return Mode::Local;
    }
    if (!mode.empty() && mode != "online") {
        std::clog << "main: unknown MODE \"" << mode << "\", falling back to online\n";
    }
    return Mode::Online;
}

// Whatever the request handler needs that comes from outside it. Online it
// comes from the environment the deployment sets - container_config.env for
// ECS - and this is where a call to Secrets Manager or Parameter Store
// belongs. Locally it is filled in with values that need no AWS account.
struct Config {
    std::string service_name;
    std::string environment;
};

Config load_config(Mode mode) {
    if (mode == Mode::Local) {
        return Config{"local", "dev"};
    }
    // Add the AWS lookups this service needs here. The task role already has
    // the permissions; nothing needs credentials.
    return Config{env_or("SERVICE_NAME"), env_or("ENVIRONMENT")};
}

std::string to_string(const std::map<std::string, std::string>& fields) {
    std::string out = "{";
    for (auto it = fields.begin(); it != fields.end(); ++it) {
        if (it != fields.begin()) {
            out += ", ";
        }
        out += it->first + ": " + it->second;
    }
    return out + "}";
}

}  // namespace

std::map<std::string, std::string> process_request(const std::string& event_data, Mode mode) {
    const Config config = load_config(mode);

    const std::map<std::string, std::string> input{
        {"event_data", event_data},
        {"mode", mode == Mode::Local ? "local" : "online"},
    };
    std::clog << "main: input: " << to_string(input) << "\n";

    const std::map<std::string, std::string> output{
        {"service", config.service_name},
        {"env", config.environment},
        {"echo", event_data},
        {"length", std::to_string(event_data.size())},
    };
    std::clog << "main: output: " << to_string(output)
              << " for input: " << to_string(input) << "\n";

    return output;
}

int main(int argc, char** argv) {
    std::string event_data = "test";
    if (argc > 1) {
        event_data = argv[1];
        for (int i = 2; i < argc; ++i) {
            event_data += " ";
            event_data += argv[i];
        }
    }

    std::cout << to_string(process_request(event_data, get_mode())) << "\n";
    return 0;
}
