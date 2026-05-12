#pragma once

#include <string>

namespace pwnapp {

enum class AppPage {
    Home,
    Stats,
    Control,
};

enum class InputKey {
    Left,
    Right,
    Enter,
    Back,
    Escape,
};

enum class ControlAction {
    Start,
    Stop,
    Restart,
    Manual,
    Auto,
};

struct PwnagotchiState {
    std::string name = "Pwnagotchi";
    std::string mood = "idle";
    std::string mode = "auto";
    std::string service_state = "unknown";
    std::string bettercap_state = "unknown";
    int channel = 0;
    int handshake_count = 0;
    int ap_count = 0;
    int client_count = 0;
    int battery_pct = 0;
    long uptime_s = 0;
    std::string last_session;
    std::string status_text = "Waiting for state";
    std::string last_error;
};

struct UiModel {
    AppPage page = AppPage::Home;
    int selected_action = 0;
    bool bridge_connected = false;
    bool action_pending = false;
    std::string action_message;
    PwnagotchiState state;
};

}  // namespace pwnapp
