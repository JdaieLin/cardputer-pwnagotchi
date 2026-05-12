#include <chrono>
#include <csignal>
#include <iostream>
#include <memory>
#include <thread>

#include "application.hpp"
#include "display_bridge.hpp"
#include "hal_evdev.hpp"
#include "pwnagotchi_client.hpp"

namespace {
volatile sig_atomic_t g_running = 1;

void signalHandler(int signum) {
    (void)signum;
    g_running = 0;
}
}  // namespace

int main() {
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);

    auto config = pwnapp::loadConfig();
    std::cout << "[main] cardputer pwnagotchi device starting" << std::endl;

    pwnapp::Application app(
        config,
        std::make_unique<pwnapp::HalEvdev>(),
        std::make_unique<pwnapp::DisplayBridge>(),
        std::make_unique<pwnapp::PwnagotchiClientBridge>());

    if (!app.start()) {
        return 1;
    }

    while (g_running && app.isRunning()) {
        app.tick();
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }

    app.stop();
    return 0;
}
