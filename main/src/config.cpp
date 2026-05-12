#include "config.hpp"

#include <cstdlib>

namespace pwnapp {
namespace {

int envInt(const char* key, int fallback) {
    const char* value = std::getenv(key);
    if (value == nullptr || *value == '\0') {
        return fallback;
    }
    return std::atoi(value);
}

std::string envString(const char* key, const std::string& fallback) {
    const char* value = std::getenv(key);
    if (value == nullptr || *value == '\0') {
        return fallback;
    }
    return std::string(value);
}

}  // namespace

AppConfig loadConfig() {
    AppConfig cfg;
    cfg.config_path = envString("PWNAGOTCHI_CONFIG", cfg.config_path);
    cfg.handshakes_dir = envString("PWNAGOTCHI_HANDSHAKES_DIR", cfg.handshakes_dir);
    cfg.service_name = envString("PWNAGOTCHI_SERVICE_NAME", cfg.service_name);
    cfg.bettercap_api_url = envString("BETTERCAP_API_URL", cfg.bettercap_api_url);
    cfg.bettercap_username = envString("BETTERCAP_USERNAME", cfg.bettercap_username);
    cfg.bettercap_password = envString("BETTERCAP_PASSWORD", cfg.bettercap_password);
    cfg.poll_interval_ms = envInt("PWNAGOTCHI_POLL_INTERVAL_MS", cfg.poll_interval_ms);
    return cfg;
}

}  // namespace pwnapp
