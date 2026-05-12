#include "pwnagotchi_client.hpp"

#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <regex>

namespace pwnapp {
namespace {

std::filesystem::path executablePath() {
#if defined(__linux__)
    std::array<char, 4096> buffer{};
    const ssize_t size = ::readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
    if (size <= 0) {
        return {};
    }
    buffer[static_cast<size_t>(size)] = '\0';
    return std::filesystem::weakly_canonical(std::filesystem::path(buffer.data()));
#else
    return {};
#endif
}

std::string bridgeScriptPath() {
    if (const char* override_path = std::getenv("PWNAGOTCHI_BRIDGE"); override_path != nullptr && *override_path != '\0') {
        if (access(override_path, R_OK) == 0) {
            return override_path;
        }
    }

    const std::filesystem::path exe = executablePath();
    if (!exe.empty()) {
        const auto share_path = exe.parent_path().parent_path() / "share" / "pwnagotchi" / "pwnagotchi_bridge.py";
        if (access(share_path.c_str(), R_OK) == 0) {
            return share_path.string();
        }
    }

    if (access("main/tools/pwnagotchi_bridge.py", R_OK) == 0) {
        return "main/tools/pwnagotchi_bridge.py";
    }
    return {};
}

std::string python3Path() {
    for (const auto& candidate : {"/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"}) {
        if (access(candidate, X_OK) == 0) {
            return candidate;
        }
    }
    return "python3";
}

std::string appendUtf8(std::string out, unsigned codepoint) {
    if (codepoint <= 0x7F) {
        out.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7FF) {
        out.push_back(static_cast<char>(0xC0 | ((codepoint >> 6) & 0x1F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else if (codepoint <= 0xFFFF) {
        out.push_back(static_cast<char>(0xE0 | ((codepoint >> 12) & 0x0F)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | ((codepoint >> 18) & 0x07)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    }
    return out;
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (c >= 'a' && c <= 'f') {
        return 10 + (c - 'a');
    }
    return -1;
}

std::string jsonUnescape(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] != '\\' || i + 1 >= text.size()) {
            out.push_back(text[i]);
            continue;
        }

        const char esc = text[++i];
        switch (esc) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                if (i + 4 >= text.size()) {
                    out += "\\u";
                    break;
                }
                unsigned codepoint = 0;
                bool ok = true;
                for (size_t j = 0; j < 4; ++j) {
                    const int value = hexValue(text[i + 1 + j]);
                    if (value < 0) {
                        ok = false;
                        break;
                    }
                    codepoint = (codepoint << 4) | static_cast<unsigned>(value);
                }
                if (!ok) {
                    out += "\\u";
                    break;
                }
                i += 4;
                out = appendUtf8(std::move(out), codepoint);
                break;
            }
            default:
                out.push_back(esc);
                break;
        }
    }
    return out;
}

}  // namespace

PwnagotchiClientBridge::PwnagotchiClientBridge() = default;

PwnagotchiClientBridge::~PwnagotchiClientBridge() {
    disconnect();
}

bool PwnagotchiClientBridge::connect(const AppConfig& cfg) {
    signal(SIGPIPE, SIG_IGN);
    disconnect();

    const std::string script_path = bridgeScriptPath();
    if (script_path.empty()) {
        std::cerr << "[bridge] pwnagotchi_bridge.py not found" << std::endl;
        return false;
    }

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
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);
        dup2(from_child[1], STDERR_FILENO);
        close(to_child[1]);
        close(from_child[0]);

        const std::string python_path = python3Path();
        execl(python_path.c_str(),
              python_path.c_str(),
              script_path.c_str(),
              "--config",
              cfg.config_path.c_str(),
              "--handshakes-dir",
              cfg.handshakes_dir.c_str(),
              "--service-name",
              cfg.service_name.c_str(),
              "--bettercap-api-url",
              cfg.bettercap_api_url.c_str(),
              "--bettercap-username",
              cfg.bettercap_username.c_str(),
              "--bettercap-password",
              cfg.bettercap_password.c_str(),
              static_cast<char*>(nullptr));
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

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (std::chrono::steady_clock::now() < deadline) {
        char buf[1024];
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

        line_buffer_.append(buf, static_cast<size_t>(n));
        while (true) {
            const size_t pos = line_buffer_.find('\n');
            if (pos == std::string::npos) {
                break;
            }
            std::string line = line_buffer_.substr(0, pos);
            line_buffer_.erase(0, pos + 1);
            if (extractStringField(line, "event") == "connected") {
                return true;
            }
        }
    }

    disconnect();
    return false;
}

void PwnagotchiClientBridge::disconnect() {
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
}

void PwnagotchiClientBridge::poll() {
    if (child_stdout_fd_ < 0) {
        return;
    }

    char buf[2048];
    while (true) {
        const ssize_t n = read(child_stdout_fd_, buf, sizeof(buf));
        if (n == 0) {
            disconnect();
            notifyDisconnected();
            break;
        }
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                disconnect();
                notifyDisconnected();
            }
            break;
        }
        line_buffer_.append(buf, static_cast<size_t>(n));
        while (true) {
            const size_t pos = line_buffer_.find('\n');
            if (pos == std::string::npos) {
                break;
            }
            std::string line = line_buffer_.substr(0, pos);
            line_buffer_.erase(0, pos + 1);
            handleEventLine(line);
        }
    }
}

void PwnagotchiClientBridge::requestState() {
    sendJsonLine("{\"cmd\":\"poll\"}");
}

void PwnagotchiClientBridge::performAction(ControlAction action) {
    sendJsonLine("{\"cmd\":\"action\",\"name\":\"" + actionName(action) + "\"}");
}

void PwnagotchiClientBridge::setOnState(std::function<void(const PwnagotchiState&)> cb) {
    on_state_ = std::move(cb);
}

void PwnagotchiClientBridge::setOnActionResult(std::function<void(bool, const std::string&)> cb) {
    on_action_result_ = std::move(cb);
}

void PwnagotchiClientBridge::setOnDisconnected(std::function<void()> cb) {
    on_disconnected_ = std::move(cb);
}

void PwnagotchiClientBridge::notifyDisconnected() {
    if (on_disconnected_) {
        on_disconnected_();
    }
}

void PwnagotchiClientBridge::sendJsonLine(const std::string& json_line) {
    if (child_stdin_fd_ < 0) {
        return;
    }
    const std::string line = json_line + "\n";
    const ssize_t n = write(child_stdin_fd_, line.c_str(), line.size());
    if (n < 0 && (errno == EPIPE || errno == EBADF)) {
        disconnect();
        notifyDisconnected();
    }
}

void PwnagotchiClientBridge::handleEventLine(const std::string& line) {
    const std::string event = extractStringField(line, "event");
    if (event == "state" && on_state_) {
        PwnagotchiState state;
        state.name = extractStringField(line, "name");
        state.mood = extractStringField(line, "mood");
        state.mode = extractStringField(line, "mode");
        state.service_state = extractStringField(line, "service_state");
        state.bettercap_state = extractStringField(line, "bettercap_state");
        state.channel = extractIntField(line, "channel", 0);
        state.handshake_count = extractIntField(line, "handshake_count", 0);
        state.ap_count = extractIntField(line, "ap_count", 0);
        state.client_count = extractIntField(line, "client_count", 0);
        state.battery_pct = extractIntField(line, "battery_pct", 0);
        state.uptime_s = extractLongField(line, "uptime_s", 0);
        state.last_session = extractStringField(line, "last_session");
        state.status_text = extractStringField(line, "status_text");
        state.last_error = extractStringField(line, "last_error");
        if (state.name.empty()) state.name = "Pwnagotchi";
        if (state.mood.empty()) state.mood = "idle";
        if (state.mode.empty()) state.mode = "auto";
        if (state.service_state.empty()) state.service_state = "unknown";
        if (state.bettercap_state.empty()) state.bettercap_state = "unknown";
        if (state.status_text.empty()) state.status_text = "State updated";
        on_state_(state);
        return;
    }

    if (event == "action_result" && on_action_result_) {
        on_action_result_(extractBoolField(line, "ok"), extractStringField(line, "message"));
    }
}

std::string PwnagotchiClientBridge::jsonEscape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 8);
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

std::string PwnagotchiClientBridge::extractStringField(const std::string& text, const std::string& key) {
    std::smatch match;
    const std::regex re("\\\"" + key + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
    if (std::regex_search(text, match, re) && match.size() > 1) {
        return jsonUnescape(match[1].str());
    }
    return {};
}

long PwnagotchiClientBridge::extractLongField(const std::string& text, const std::string& key, long fallback) {
    std::smatch match;
    const std::regex re("\\\"" + key + "\\\"\\s*:\\s*(-?[0-9]+)");
    if (std::regex_search(text, match, re) && match.size() > 1) {
        return std::stol(match[1].str());
    }
    return fallback;
}

int PwnagotchiClientBridge::extractIntField(const std::string& text, const std::string& key, int fallback) {
    return static_cast<int>(extractLongField(text, key, fallback));
}

bool PwnagotchiClientBridge::extractBoolField(const std::string& text, const std::string& key) {
    std::smatch match;
    const std::regex re("\\\"" + key + "\\\"\\s*:\\s*(true|false)");
    if (std::regex_search(text, match, re) && match.size() > 1) {
        return match[1].str() == "true";
    }
    return false;
}

std::string PwnagotchiClientBridge::actionName(ControlAction action) {
    switch (action) {
        case ControlAction::Start: return "start_service";
        case ControlAction::Stop: return "stop_service";
        case ControlAction::Restart: return "restart_service";
        case ControlAction::Manual: return "set_manual";
        case ControlAction::Auto: return "set_auto";
    }
    return "restart_service";
}

}  // namespace pwnapp
