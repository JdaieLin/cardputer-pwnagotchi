#include "display_bridge.hpp"

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace pwnapp {
namespace {

std::string bridgeScriptPath() {
    if (const char* override_path = std::getenv("PWNAGOTCHI_DISPLAY_BRIDGE"); override_path != nullptr && *override_path != '\0') {
        if (access(override_path, R_OK) == 0) {
            return override_path;
        }
    }

    std::array<char, 4096> buf{};
    const ssize_t size = ::readlink("/proc/self/exe", buf.data(), buf.size() - 1);
    if (size > 0) {
        buf[static_cast<size_t>(size)] = '\0';
        std::filesystem::path exe(buf.data());
        std::filesystem::path dir = exe.parent_path().parent_path() / "share" / "pwnagotchi";
        std::filesystem::path script = dir / "display_bridge.py";
        if (access(script.c_str(), R_OK) == 0) {
            return script.string();
        }
    }

    return "main/tools/display_bridge.py";
}

std::string python3Path() {
    for (const auto& candidate : {"/usr/bin/python3", "/usr/local/bin/python3"}) {
        if (access(candidate, X_OK) == 0) return candidate;
    }
    return "python3";
}

}  // namespace

DisplayBridge::DisplayBridge() = default;

DisplayBridge::~DisplayBridge() {
    disconnect();
}

bool DisplayBridge::init() {
    signal(SIGPIPE, SIG_IGN);

    int to_child[2] = {-1, -1};
    int from_child[2] = {-1, -1};
    if (pipe(to_child) != 0 || pipe(from_child) != 0) {
        return false;
    }

    const pid_t pid = fork();
    if (pid < 0) {
        return false;
    }

    if (pid == 0) {
        const std::string script_path = bridgeScriptPath();
        const std::string python_path = python3Path();
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);
        dup2(from_child[1], STDERR_FILENO);
        close(to_child[1]);
        close(from_child[0]);
        execl(python_path.c_str(), python_path.c_str(), script_path.c_str(), static_cast<char*>(nullptr));
        _exit(1);
    }

    child_pid_ = static_cast<int>(pid);
    child_stdin_fd_ = to_child[1];
    child_stdout_fd_ = from_child[0];
    close(to_child[0]);
    close(from_child[1]);

    const int flags = fcntl(child_stdout_fd_, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(child_stdout_fd_, F_SETFL, flags | O_NONBLOCK);
    }

    std::string line_buffer;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (std::chrono::steady_clock::now() < deadline) {
        char buf[512];
        const ssize_t n = read(child_stdout_fd_, buf, sizeof(buf));
        if (n == 0) {
            disconnect();
            return false;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(20 * 1000);
                continue;
            }
            disconnect();
            return false;
        }

        line_buffer.append(buf, static_cast<size_t>(n));
        while (true) {
            const size_t pos = line_buffer.find('\n');
            if (pos == std::string::npos) {
                break;
            }
            std::string line = line_buffer.substr(0, pos);
            line_buffer.erase(0, pos + 1);
            if (line.find("\"connected\"") != std::string::npos) {
                connected_ = true;
                return true;
            }
        }
    }

    disconnect();
    return false;
}

void DisplayBridge::disconnect() {
    if (child_stdin_fd_ >= 0) {
        close(child_stdin_fd_);
        child_stdin_fd_ = -1;
    }
    if (child_stdout_fd_ >= 0) {
        close(child_stdout_fd_);
        child_stdout_fd_ = -1;
    }
    if (child_pid_ > 0) {
        kill(child_pid_, SIGTERM);
        int status = 0;
        waitpid(child_pid_, &status, WNOHANG);
        child_pid_ = -1;
    }
    connected_ = false;
}

void DisplayBridge::sendJsonLine(const std::string& json_line) {
    if (child_stdin_fd_ < 0 || !connected_) {
        return;
    }
    const std::string line = json_line + "\n";
    static_cast<void>(write(child_stdin_fd_, line.c_str(), line.size()));
}

void DisplayBridge::render(const UiModel& model) {
    if (!connected_) {
        return;
    }

    std::string json = "{\"cmd\":\"render\",";
    json += "\"page\":\"" + std::string(pageName(model.page)) + "\",";
    json += "\"selected_action\":" + std::to_string(model.selected_action) + ",";
    json += "\"bridge_connected\":" + std::string(model.bridge_connected ? "true" : "false") + ",";
    json += "\"action_pending\":" + std::string(model.action_pending ? "true" : "false") + ",";
    json += "\"action_message\":\"" + jsonEscape(model.action_message) + "\",";
    json += "\"name\":\"" + jsonEscape(model.state.name) + "\",";
    json += "\"mood\":\"" + jsonEscape(model.state.mood) + "\",";
    json += "\"mode\":\"" + jsonEscape(model.state.mode) + "\",";
    json += "\"service_state\":\"" + jsonEscape(model.state.service_state) + "\",";
    json += "\"bettercap_state\":\"" + jsonEscape(model.state.bettercap_state) + "\",";
    json += "\"channel\":" + std::to_string(model.state.channel) + ",";
    json += "\"handshake_count\":" + std::to_string(model.state.handshake_count) + ",";
    json += "\"ap_count\":" + std::to_string(model.state.ap_count) + ",";
    json += "\"client_count\":" + std::to_string(model.state.client_count) + ",";
    json += "\"battery_pct\":" + std::to_string(model.state.battery_pct) + ",";
    json += "\"uptime_s\":" + std::to_string(model.state.uptime_s) + ",";
    json += "\"last_session\":\"" + jsonEscape(model.state.last_session) + "\",";
    json += "\"status_text\":\"" + jsonEscape(model.state.status_text) + "\",";
    json += "\"last_error\":\"" + jsonEscape(model.state.last_error) + "\"}";
    sendJsonLine(json);
}

std::string DisplayBridge::jsonEscape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 16);
    for (char c : text) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out.push_back(c); break;
        }
    }
    return out;
}

const char* DisplayBridge::pageName(AppPage page) {
    switch (page) {
        case AppPage::Home: return "HOME";
        case AppPage::Stats: return "STATS";
        case AppPage::Control: return "CONTROL";
    }
    return "HOME";
}

}  // namespace pwnapp
