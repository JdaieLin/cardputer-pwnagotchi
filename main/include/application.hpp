#pragma once

#include <chrono>
#include <memory>
#include <string>

#include "config.hpp"
#include "display_bridge.hpp"
#include "hal.hpp"
#include "pwnagotchi_client.hpp"
#include "types.hpp"
#include "ui.hpp"

namespace pwnapp {

class Application {
public:
    Application(AppConfig cfg,
                std::unique_ptr<Hal> hal,
                std::unique_ptr<Ui> ui,
                std::unique_ptr<PwnagotchiClient> client);

    bool start();
    void stop();
    void tick();
    bool isRunning() const;

private:
    void onKey(InputKey key);
    void onState(const PwnagotchiState& state);
    void onActionResult(bool ok, const std::string& message);
    void onBridgeDisconnected();
    void reconnectIfDue();
    void renderUi(bool force = false);
    void requestStateIfDue();
    static ControlAction selectedAction(int index);

    AppConfig cfg_;
    UiModel model_;
    bool running_ = false;
    std::chrono::steady_clock::time_point last_ui_refresh_{};
    std::chrono::steady_clock::time_point last_poll_{};
    std::chrono::steady_clock::time_point last_reconnect_{};

    std::unique_ptr<Hal> hal_;
    std::unique_ptr<Ui> ui_;
    std::unique_ptr<PwnagotchiClient> client_;
};

}  // namespace pwnapp
