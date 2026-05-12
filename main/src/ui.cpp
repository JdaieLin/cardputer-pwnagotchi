#include "ui.hpp"

#include <iostream>

namespace pwnapp {
namespace {

const char* pageName(AppPage page) {
    switch (page) {
        case AppPage::Home: return "HOME";
        case AppPage::Stats: return "STATS";
        case AppPage::Control: return "CONTROL";
    }
    return "UNKNOWN";
}

}  // namespace

bool UiStub::init() {
    std::cout << "[ui] init stub" << std::endl;
    return true;
}

void UiStub::render(const UiModel& model) {
    std::cout << "[ui] page=" << pageName(model.page)
              << " name=" << model.state.name
              << " mood=" << model.state.mood
              << " status=" << model.state.status_text << std::endl;
}

}  // namespace pwnapp
