#pragma once

#include <functional>

#include "hal.hpp"

namespace pwnapp {

class HalEvdev final : public Hal {
public:
    HalEvdev();
    ~HalEvdev() override;

    bool init() override;
    void poll() override;
    bool shouldQuit() const override;
    void onKey(std::function<void(InputKey)> cb) override;

private:
    std::function<void(InputKey)> key_cb_;
    int fd_ = -1;
    bool should_quit_ = false;
};

}  // namespace pwnapp
