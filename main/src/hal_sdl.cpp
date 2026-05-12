#include "hal_sdl.hpp"

#include <iostream>

namespace pwnapp {
namespace {

bool g_sdl_video_ok = false;

}  // namespace

bool sdlVideoOk() {
    return g_sdl_video_ok;
}

HalSdl::~HalSdl() {
    SDL_Quit();
}

bool HalSdl::init() {
    const int rc = SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
    if (rc == 0) {
        g_sdl_video_ok = true;
        std::cout << "[hal-sdl] initialized with video" << std::endl;
        return true;
    }

    std::cerr << "[hal-sdl] SDL_Init(video+events) failed: " << SDL_GetError() << std::endl;
    SDL_Quit();
    if (SDL_Init(SDL_INIT_EVENTS) != 0) {
        std::cerr << "[hal-sdl] SDL_Init(events) failed: " << SDL_GetError() << std::endl;
        return false;
    }

    g_sdl_video_ok = false;
    std::cout << "[hal-sdl] initialized headless" << std::endl;
    return true;
}

void HalSdl::poll() {
    SDL_Event event;
    while (SDL_PollEvent(&event) == 1) {
        if (event.type == SDL_QUIT) {
            should_quit_ = true;
            continue;
        }
        if (event.type != SDL_KEYDOWN || event.key.repeat != 0 || !key_cb_) {
            continue;
        }

        switch (event.key.keysym.sym) {
            case SDLK_LEFT:
                key_cb_(InputKey::Left);
                break;
            case SDLK_RIGHT:
                key_cb_(InputKey::Right);
                break;
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                key_cb_(InputKey::Enter);
                break;
            case SDLK_BACKSPACE:
                key_cb_(InputKey::Back);
                break;
            case SDLK_ESCAPE:
                key_cb_(InputKey::Escape);
                should_quit_ = true;
                break;
            default:
                break;
        }
    }
}

bool HalSdl::shouldQuit() const {
    return should_quit_;
}

void HalSdl::onKey(std::function<void(InputKey)> cb) {
    key_cb_ = std::move(cb);
}

}  // namespace pwnapp
