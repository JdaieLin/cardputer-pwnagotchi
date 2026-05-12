#include <chrono>
#include <iostream>
#include <memory>
#include <thread>

#include "application.hpp"
#include "hal_sdl.hpp"
#include "pwnagotchi_client.hpp"
#include "ui_sdl.hpp"

int main() {
    auto config = pwnapp::loadConfig();
    std::cout << "[main] cardputer pwnagotchi simulator starting" << std::endl;

    pwnapp::Application app(
        config,
        std::make_unique<pwnapp::HalSdl>(),
        std::make_unique<pwnapp::UiSdl>(),
        std::make_unique<pwnapp::PwnagotchiClientBridge>());

    if (!app.start()) {
        return 1;
    }

    while (app.isRunning()) {
        app.tick();
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }

    app.stop();
    return 0;
}
