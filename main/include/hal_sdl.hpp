#pragma once

#include <functional>

#include <SDL.h>

#include "hal.hpp"

namespace pwnapp {

bool sdlVideoOk();

class HalSdl final : public Hal {
public:
    HalSdl() = default;
    ~HalSdl() override;

    bool init() override;
    void poll() override;
    bool shouldQuit() const override;
    void onKey(std::function<void(InputKey)> cb) override;

private:
    std::function<void(InputKey)> key_cb_;
    bool should_quit_ = false;
};

}  // namespace pwnapp
