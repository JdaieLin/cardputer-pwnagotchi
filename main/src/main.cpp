#include <chrono>
#include <iostream>
#include <memory>
#include <thread>

#include "application.hpp"
#include "hal.hpp"
#include "pwnagotchi_client.hpp"
#include "ui.hpp"

int main() {
    auto config = pwnapp::loadConfig();
    std::cout << "[main] cardputer pwnagotchi stub starting" << std::endl;

    pwnapp::Application app(
        config,
        std::make_unique<pwnapp::HalStub>(),
        std::make_unique<pwnapp::UiStub>(),
        std::make_unique<pwnapp::PwnagotchiClientBridge>());

    if (!app.start()) {
        return 1;
    }

    while (app.isRunning()) {
        app.tick();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    app.stop();
    return 0;
}
