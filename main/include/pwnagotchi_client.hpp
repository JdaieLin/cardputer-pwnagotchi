#pragma once

#include <functional>
#include <string>

#include "config.hpp"
#include "types.hpp"

namespace pwnapp {

class PwnagotchiClient {
public:
    virtual ~PwnagotchiClient() = default;
    virtual bool connect(const AppConfig& cfg) = 0;
    virtual void disconnect() = 0;
    virtual void poll() = 0;
    virtual void requestState() = 0;
    virtual void performAction(ControlAction action) = 0;
    virtual void setOnState(std::function<void(const PwnagotchiState&)> cb) = 0;
    virtual void setOnActionResult(std::function<void(bool, const std::string&)> cb) = 0;
    virtual void setOnDisconnected(std::function<void()> cb) = 0;
};

class PwnagotchiClientBridge final : public PwnagotchiClient {
public:
    PwnagotchiClientBridge();
    ~PwnagotchiClientBridge() override;

    bool connect(const AppConfig& cfg) override;
    void disconnect() override;
    void poll() override;
    void requestState() override;
    void performAction(ControlAction action) override;
    void setOnState(std::function<void(const PwnagotchiState&)> cb) override;
    void setOnActionResult(std::function<void(bool, const std::string&)> cb) override;
    void setOnDisconnected(std::function<void()> cb) override;

private:
    void notifyDisconnected();
    void sendJsonLine(const std::string& json_line);
    void handleEventLine(const std::string& line);
    static std::string jsonEscape(const std::string& text);
    static std::string extractStringField(const std::string& text, const std::string& key);
    static long extractLongField(const std::string& text, const std::string& key, long fallback = 0);
    static int extractIntField(const std::string& text, const std::string& key, int fallback = 0);
    static bool extractBoolField(const std::string& text, const std::string& key);
    static std::string actionName(ControlAction action);

    int child_stdin_fd_ = -1;
    int child_stdout_fd_ = -1;
    int child_pid_ = -1;
    std::string line_buffer_;
    std::function<void(const PwnagotchiState&)> on_state_;
    std::function<void(bool, const std::string&)> on_action_result_;
    std::function<void()> on_disconnected_;
};

}  // namespace pwnapp
