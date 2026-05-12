#include "ui_sdl.hpp"

#include <iomanip>
#include <iostream>
#include <sstream>
#include <vector>

#include "hal_sdl.hpp"
#include "text_renderer_sdl.hpp"

namespace pwnapp {
namespace {

using xiaozhi::drawSdlText;

std::vector<std::string> splitUtf8Glyphs(const std::string& text) {
    std::vector<std::string> glyphs;
    for (size_t i = 0; i < text.size();) {
        unsigned char lead = static_cast<unsigned char>(text[i]);
        size_t width = 1;
        if ((lead & 0xE0) == 0xC0) width = 2;
        else if ((lead & 0xF0) == 0xE0) width = 3;
        else if ((lead & 0xF8) == 0xF0) width = 4;
        width = std::min(width, text.size() - i);
        glyphs.emplace_back(text.substr(i, width));
        i += width;
    }
    return glyphs;
}

std::string faceForMood(const std::string& mood) {
    if (mood == "happy-handshake") return "(•‿‿•)";
    if (mood == "listening-scanning") return "(⌐■_■)";
    if (mood == "busy") return "(°▃▃°)";
    if (mood == "error") return "(☓‿‿☓)";
    return "(◕‿‿◕)";
}

std::string modeLabel(const std::string& mode) {
    return mode == "manual" ? "MANU" : "AUTO";
}

std::string uptimeLabel(long uptime_s) {
    const long hours = uptime_s / 3600;
    const long minutes = (uptime_s % 3600) / 60;
    std::ostringstream oss;
    oss << std::setw(2) << std::setfill('0') << hours
        << ":" << std::setw(2) << std::setfill('0') << minutes;
    return oss.str();
}

std::string pwnedLabel(int count) {
    std::ostringstream oss;
    oss << "PWND " << count << " (" << std::setw(2) << std::setfill('0') << count << ")";
    return oss.str();
}

}  // namespace

UiSdl::~UiSdl() {
    if (renderer_ != nullptr) SDL_DestroyRenderer(renderer_);
    if (window_ != nullptr) SDL_DestroyWindow(window_);
}

bool UiSdl::init() {
    if (const char* path = std::getenv("CARDPUTER_UI_SNAPSHOT_PATH"); path != nullptr) {
        snapshot_path_ = path;
    }

    if (!sdlVideoOk()) {
        std::cout << "[ui-sdl] headless" << std::endl;
        return true;
    }

    window_ = SDL_CreateWindow("cardputer-pwnagotchi",
                               SDL_WINDOWPOS_CENTERED,
                               SDL_WINDOWPOS_CENTERED,
                               480,
                               280,
                               SDL_WINDOW_SHOWN);
    if (window_ == nullptr) {
        return true;
    }

    renderer_ = SDL_CreateRenderer(window_, -1, snapshot_path_.empty() ? SDL_RENDERER_ACCELERATED : SDL_RENDERER_SOFTWARE);
    if (renderer_ == nullptr) {
        SDL_DestroyWindow(window_);
        window_ = nullptr;
        return true;
    }
    return true;
}

void UiSdl::render(const UiModel& model) {
    if (renderer_ == nullptr || window_ == nullptr) {
        std::cout << "[ui-sdl] " << model.state.status_text << std::endl;
        return;
    }

    SDL_SetRenderDrawColor(renderer_, 255, 255, 255, 255);
    SDL_RenderClear(renderer_);

    SDL_SetRenderDrawColor(renderer_, 0, 0, 0, 255);
    SDL_Rect border{18, 16, 444, 248};
    SDL_RenderDrawRect(renderer_, &border);

    drawSdlText(renderer_, {28, 24, 70, 18}, "CH " + std::to_string(model.state.channel), {{0, 0, 0, 255}, 14.0f, true, false, false});
    drawSdlText(renderer_, {104, 24, 82, 18}, "APS " + std::to_string(model.state.ap_count), {{0, 0, 0, 255}, 14.0f, true, false, false});
    drawSdlText(renderer_, {264, 24, 84, 18}, "BAT " + std::to_string(model.state.battery_pct), {{0, 0, 0, 255}, 14.0f, true, false, false});
    drawSdlText(renderer_, {356, 24, 88, 18}, "UP " + uptimeLabel(model.state.uptime_s), {{0, 0, 0, 255}, 14.0f, true, false, false});

    drawSdlText(renderer_, {42, 78, 170, 66}, faceForMood(model.state.mood), {{0, 0, 0, 255}, 30.0f, true, true, false});
    drawSdlText(renderer_, {236, 74, 180, 72}, marqueeText(model.action_message.empty() ? model.state.status_text : model.action_message), {{0, 0, 0, 255}, 16.0f, false, false, true});

    SDL_SetRenderDrawColor(renderer_, 0, 0, 0, 255);
    SDL_RenderDrawLine(renderer_, 30, 188, 448, 188);

    drawSdlText(renderer_, {30, 204, 220, 20}, pwnedLabel(model.state.handshake_count), {{0, 0, 0, 255}, 16.0f, true, false, false});
    drawSdlText(renderer_, {360, 204, 76, 20}, modeLabel(model.state.mode), {{0, 0, 0, 255}, 16.0f, true, false, true});

    SDL_RenderPresent(renderer_);
    saveSnapshotIfEnabled();
}

void UiSdl::saveSnapshotIfEnabled() {
    if (snapshot_path_.empty() || renderer_ == nullptr) {
        return;
    }
    int width = 0;
    int height = 0;
    if (SDL_GetRendererOutputSize(renderer_, &width, &height) != 0 || width <= 0 || height <= 0) {
        return;
    }
    SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormat(0, width, height, 32, SDL_PIXELFORMAT_ARGB8888);
    if (surface == nullptr) {
        return;
    }
    if (SDL_RenderReadPixels(renderer_, nullptr, SDL_PIXELFORMAT_ARGB8888, surface->pixels, surface->pitch) == 0) {
        SDL_SaveBMP(surface, snapshot_path_.c_str());
    }
    SDL_FreeSurface(surface);
}

std::string UiSdl::marqueeText(const std::string& text) {
    constexpr size_t kVisibleGlyphs = 24;
    constexpr Uint32 kStepMs = 350;
    const std::vector<std::string> glyphs = splitUtf8Glyphs(text);
    if (glyphs.size() <= kVisibleGlyphs) {
        marquee_source_text_.clear();
        marquee_start_ticks_ = 0;
        return text;
    }
    if (text != marquee_source_text_) {
        marquee_source_text_ = text;
        marquee_start_ticks_ = SDL_GetTicks();
    }
    const size_t max_offset = glyphs.size() - kVisibleGlyphs;
    const size_t offset = std::min(max_offset, static_cast<size_t>((SDL_GetTicks() - marquee_start_ticks_) / kStepMs));
    std::string out;
    for (size_t i = 0; i < kVisibleGlyphs && offset + i < glyphs.size(); ++i) {
        out += glyphs[offset + i];
    }
    return out;
}

const char* UiSdl::pageName(AppPage page) {
    switch (page) {
        case AppPage::Home: return "HOME";
        case AppPage::Stats: return "STATS";
        case AppPage::Control: return "CONTROL";
    }
    return "HOME";
}

std::string UiSdl::moodEmoji(const std::string& mood) {
    return faceForMood(mood);
}

}  // namespace pwnapp
