#pragma once

#include <string>

#include <SDL.h>

#include "ui.hpp"

namespace pwnapp {

class UiSdl final : public Ui {
public:
    UiSdl() = default;
    ~UiSdl() override;

    bool init() override;
    void render(const UiModel& model) override;

private:
    void saveSnapshotIfEnabled();
    std::string marqueeText(const std::string& text);
    static const char* pageName(AppPage page);
    static std::string moodEmoji(const std::string& mood);

    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    std::string snapshot_path_;
    std::string marquee_source_text_;
    Uint32 marquee_start_ticks_ = 0;
};

}  // namespace pwnapp
