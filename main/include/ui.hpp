#pragma once

#include "types.hpp"

namespace pwnapp {

class Ui {
public:
    virtual ~Ui() = default;
    virtual bool init() = 0;
    virtual void shutdown() {}
    virtual void render(const UiModel& model) = 0;
};

class UiStub final : public Ui {
public:
    bool init() override;
    void render(const UiModel& model) override;
};

}  // namespace pwnapp
