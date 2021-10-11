#include "wf-lua.hpp"

#include <wayfire/config/compound-option.hpp>
#include <wayfire/config/config-manager.hpp>
#include <wayfire/core.hpp>
#include <wayfire/debug.hpp>
#include <wayfire/output-layout.hpp>
#include <wayfire/signal-definitions.hpp>

using CfgSection = std::shared_ptr<wf::config::section_t>;

template <typename T>
using CfgOption = std::shared_ptr<wf::config::option_t<T>>;

extern "C" {

wf_Error wf_set_option_str(const char *section, const char *option,
                           const char *val) {
    auto &core = wf::get_core();

    auto sec = core.config.get_section(section);
    if (!sec)
        return wf_Error::WF_INVALID_OPTION_SECTION;

    auto opt = sec->get_option_or(option);
    if (!opt)
        return wf_Error::WF_INVALID_OPTION;

    if (opt->set_value_str(val)) {
        LOGD("Option set: ", section, "/", option, " = ", val);
        return wf_Error::WF_OK;
    }
    return wf_Error::WF_INVALID_OPTION_VALUE;
}

void wf_register_event_callback(const wf_EventCallback callback) {
    wf_lua::get_plugin()->register_event_callback(callback);
}

void wf_signal_subscribe(void *object, const char *signal) {
    wf_lua::get_plugin()->signal_subscribe(object, signal);
}

void wf_signal_unsubscribe(void *object, const char *signal) {
    wf_lua::get_plugin()->signal_unsubscribe(object, signal);
}

wf_Output *wf_get_next_output(wf_Output *prev) {
    const auto &outputs = wf::get_core().output_layout;
    return (wf_Output *)outputs->get_next_output((wf::output_t *)prev);
}

wf_View *wf_get_signaled_view(void *sig_data) {
    return (wf_View *)wf::get_signaled_view((wf::signal_data_t *)sig_data)
        .get();
}

/// Temporary return string buffer. Meant to be copied from before next call.
static std::string string_buf;

#define WRAP_STRING_METHOD(CTYPE, METHOD, TYPE)                                \
    const char *CTYPE##_##METHOD(CTYPE *object) {                              \
        string_buf = ((TYPE *)object)->METHOD();                               \
        return string_buf.c_str();                                             \
    }

WRAP_STRING_METHOD(wf_View, to_string, wf::view_interface_t)
WRAP_STRING_METHOD(wf_View, get_title, wf::view_interface_t)
WRAP_STRING_METHOD(wf_View, get_app_id, wf::view_interface_t)
WRAP_STRING_METHOD(wf_Output, to_string, wf::output_t)
#undef DEF_TO_STRING
}
