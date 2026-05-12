#include "hal_evdev.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <linux/input.h>
#include <unistd.h>

namespace pwnapp {

HalEvdev::HalEvdev() = default;

HalEvdev::~HalEvdev() {
    if (fd_ >= 0) {
        close(fd_);
    }
}

bool HalEvdev::init() {
    const char* device = std::getenv("APPLAUNCH_LINUX_KEYBOARD_DEVICE");
    if (device == nullptr || *device == '\0') {
        device = std::getenv("PWNAGOTCHI_KEYBOARD_DEVICE");
    }
    if (device == nullptr || *device == '\0') {
        device = "/dev/input/by-path/platform-3f804000.i2c-event";
    }

    fd_ = open(device, O_RDONLY | O_NONBLOCK);
    if (fd_ < 0) {
        std::cerr << "[hal-evdev] failed to open " << device << ": " << std::strerror(errno) << std::endl;
        return false;
    }

    std::cout << "[hal-evdev] initialized on " << device << std::endl;
    return true;
}

void HalEvdev::poll() {
    if (fd_ < 0) {
        return;
    }

    struct input_event ev;
    while (true) {
        const ssize_t n = read(fd_, &ev, sizeof(ev));
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                should_quit_ = true;
            }
            break;
        }
        if (n == 0) {
            should_quit_ = true;
            break;
        }
        if (static_cast<size_t>(n) < sizeof(ev) || ev.type != EV_KEY || ev.value != 1 || !key_cb_) {
            continue;
        }

        switch (ev.code) {
            case KEY_LEFT:
                key_cb_(InputKey::Left);
                break;
            case KEY_RIGHT:
                key_cb_(InputKey::Right);
                break;
            case KEY_ENTER:
                key_cb_(InputKey::Enter);
                break;
            case KEY_BACKSPACE:
                key_cb_(InputKey::Back);
                break;
            case KEY_HOME:
            case KEY_ESC:
                key_cb_(InputKey::Escape);
                break;
            default:
                break;
        }
    }
}

bool HalEvdev::shouldQuit() const {
    return should_quit_;
}

void HalEvdev::onKey(std::function<void(InputKey)> cb) {
    key_cb_ = std::move(cb);
}

}  // namespace pwnapp
