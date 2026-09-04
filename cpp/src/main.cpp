// Mirrors the Python and Go stubs: one process_request() that every target
// funnels into, so the behaviour is the same however this is deployed.

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>

#include <openssl/evp.h>

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

// f1 mirrors lib/package_a/module_x.py in the Python layer: the one piece of
// work the template does, so there is something to replace with the real
// thing.
std::string f1(const std::map<std::string, std::string>& input) {
    const std::string rendered = to_string(input);

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;

    EVP_MD_CTX* context = EVP_MD_CTX_new();
    EVP_DigestInit_ex(context, EVP_sha256(), nullptr);
    EVP_DigestUpdate(context, rendered.data(), rendered.size());
    EVP_DigestFinal_ex(context, digest, &length);
    EVP_MD_CTX_free(context);

    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned int i = 0; i < length; ++i) {
        out << std::setw(2) << static_cast<int>(digest[i]);
    }
    return out.str();
}

}  // namespace

std::string process_request(const std::string& event_data, Mode mode) {
    if (mode == Mode::Online) {
        // Where the AWS lookups belong: anything that must not sit in the
        // environment file - endpoints, credentials, keys - comes from
        // Secrets Manager, read with the task role. The Python and Go layers
        // do this through gig_utils; this one has no AWS SDK linked yet, so
        // the call goes here when the service needs one. Log that a secret
        // was read, never what it contained.
        std::clog << "main: online - add the Secrets Manager read here\n";
    }

    const std::map<std::string, std::string> input{{"event_data", event_data}};
    std::clog << "main: input: " << to_string(input) << "\n";

    const std::string output = f1(input);

    std::clog << "main: output: " << output << " for input: " << to_string(input) << "\n";
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

    std::cout << process_request(event_data, get_mode()) << "\n";
    return 0;
}
