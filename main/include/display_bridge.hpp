#pragma once

#include <string>

#include "ui.hpp"

namespace pwnapp {

class DisplayBridge final : public Ui {
public:
    DisplayBridge();
    ~DisplayBridge() override;

    bool init() override;
    void render(const UiModel& model) override;
    void disconnect();

private:
    void sendJsonLine(const std::string& json_line);
    static std::string jsonEscape(const std::string& text);
    static const char* pageName(AppPage page);

    int child_stdin_fd_ = -1;
    int child_stdout_fd_ = -1;
    int child_pid_ = -1;
    bool connected_ = false;
};

}  // namespace pwnapp
