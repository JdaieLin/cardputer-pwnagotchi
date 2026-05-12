#include "hal.hpp"

#include <iostream>

namespace pwnapp {

bool HalStub::init() {
    std::cout << "[hal] init stub" << std::endl;
    return true;
}

void HalStub::poll() {
}

void HalStub::onKey(std::function<void(InputKey)> cb) {
    key_cb_ = std::move(cb);
}

}  // namespace pwnapp
