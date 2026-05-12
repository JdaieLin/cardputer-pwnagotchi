#pragma once

#include <functional>

#include "types.hpp"

namespace pwnapp {

class Hal {
public:
    virtual ~Hal() = default;
    virtual bool init() = 0;
    virtual void poll() = 0;
    virtual bool shouldQuit() const { return false; }
    virtual void onKey(std::function<void(InputKey)> cb) = 0;
};

class HalStub final : public Hal {
public:
    bool init() override;
    void poll() override;
    void onKey(std::function<void(InputKey)> cb) override;

private:
    std::function<void(InputKey)> key_cb_;
};

}  // namespace pwnapp
