#include "application.hpp"

#include <iostream>
#include <utility>

namespace pwnapp {

Application::Application(AppConfig cfg,
                         std::unique_ptr<Hal> hal,
                         std::unique_ptr<Ui> ui,
                         std::unique_ptr<PwnagotchiClient> client)
    : cfg_(std::move(cfg)),
      hal_(std::move(hal)),
      ui_(std::move(ui)),
      client_(std::move(client)) {}

bool Application::start() {
    if (!hal_->init()) {
        return false;
    }
    if (!ui_->init()) {
        std::cerr << "[app] ui init failed" << std::endl;
    }

    hal_->onKey([this](InputKey key) { onKey(key); });
    client_->setOnState([this](const PwnagotchiState& state) { onState(state); });
    client_->setOnActionResult([this](bool ok, const std::string& message) { onActionResult(ok, message); });
    client_->setOnDisconnected([this]() { onBridgeDisconnected(); });

    running_ = client_->connect(cfg_);
    model_.bridge_connected = running_;
    model_.state.status_text = running_ ? "Bridge connected" : "Bridge unavailable";
    last_ui_refresh_ = std::chrono::steady_clock::now() - std::chrono::seconds(1);
    last_poll_ = std::chrono::steady_clock::now() - std::chrono::milliseconds(cfg_.poll_interval_ms);
    last_reconnect_ = std::chrono::steady_clock::now() - std::chrono::seconds(5);
    renderUi(true);
    return running_;
}

void Application::stop() {
    if (!running_) {
        return;
    }
    running_ = false;
    ui_->shutdown();
    client_->disconnect();
}

void Application::tick() {
    if (!running_) {
        return;
    }

    hal_->poll();
    if (!running_) {
        return;
    }
    if (hal_->shouldQuit()) {
        stop();
        return;
    }

    client_->poll();
    reconnectIfDue();
    requestStateIfDue();
    renderUi();
}

bool Application::isRunning() const {
    return running_;
}

void Application::onKey(InputKey key) {
    if (key == InputKey::Escape) {
        stop();
        return;
    }

    if (key == InputKey::Left) {
        if (model_.page == AppPage::Home) model_.page = AppPage::Control;
        else if (model_.page == AppPage::Stats) model_.page = AppPage::Home;
        else model_.page = AppPage::Stats;
        renderUi(true);
        return;
    }

    if (key == InputKey::Right) {
        if (model_.page == AppPage::Home) model_.page = AppPage::Stats;
        else if (model_.page == AppPage::Stats) model_.page = AppPage::Control;
        else model_.page = AppPage::Home;
        renderUi(true);
        return;
    }

    if (key == InputKey::Back) {
        model_.page = AppPage::Home;
        renderUi(true);
        return;
    }

    if (key == InputKey::Enter && model_.page == AppPage::Control) {
        model_.action_pending = true;
        model_.action_message = "Running action...";
        client_->performAction(selectedAction(model_.selected_action));
        renderUi(true);
        return;
    }

    if (key == InputKey::Enter) {
        model_.page = AppPage::Control;
        renderUi(true);
    }
}

void Application::onState(const PwnagotchiState& state) {
    model_.state = state;
    model_.bridge_connected = true;
    renderUi(true);
}

void Application::onActionResult(bool ok, const std::string& message) {
    model_.action_pending = false;
    model_.action_message = ok ? ("OK: " + message) : ("FAIL: " + message);
    if (!ok) {
        model_.state.last_error = message;
    } else if (!message.empty()) {
        model_.state.status_text = message;
    }
    renderUi(true);
}

void Application::onBridgeDisconnected() {
    model_.bridge_connected = false;
    model_.action_pending = false;
    model_.state.status_text = "Reconnecting bridge...";
    renderUi(true);
}

void Application::reconnectIfDue() {
    if (model_.bridge_connected) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now - last_reconnect_ < std::chrono::seconds(3)) {
        return;
    }
    last_reconnect_ = now;
    if (client_->connect(cfg_)) {
        model_.bridge_connected = true;
        model_.state.status_text = "Bridge reconnected";
        model_.state.last_error.clear();
        last_poll_ = now - std::chrono::milliseconds(cfg_.poll_interval_ms);
        renderUi(true);
    }
}

void Application::renderUi(bool force) {
    if (!running_) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (!force && now - last_ui_refresh_ < std::chrono::milliseconds(120)) {
        return;
    }
    last_ui_refresh_ = now;
    ui_->render(model_);
}

void Application::requestStateIfDue() {
    const auto now = std::chrono::steady_clock::now();
    if (now - last_poll_ < std::chrono::milliseconds(cfg_.poll_interval_ms)) {
        return;
    }
    last_poll_ = now;
    client_->requestState();
}

ControlAction Application::selectedAction(int index) {
    switch (index) {
        case 0: return ControlAction::Start;
        case 1: return ControlAction::Stop;
        case 2: return ControlAction::Restart;
        case 3: return ControlAction::Manual;
        case 4: return ControlAction::Auto;
        default: return ControlAction::Restart;
    }
}

}  // namespace pwnapp
