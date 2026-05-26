#pragma once

#include <string>

namespace pwnapp {

struct AppConfig {
    std::string config_path = "/etc/pwnagotchi/config.toml";
    std::string handshakes_dir = "/home/pi/handshakes";
    std::string service_name = "pwnagotchi";
    std::string bettercap_api_url = "http://127.0.0.1:8081/api";
    std::string bettercap_username = "pwnagotchi";
    std::string bettercap_password = "pwnagotchi";
    int poll_interval_ms = 1500;
};

AppConfig loadConfig();

}  // namespace pwnapp
