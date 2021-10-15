#include "wf-lua.hpp"

#include <wayfire/config/compound-option.hpp>
#include <wayfire/config/config-manager.hpp>
#include <wayfire/core.hpp>
#include <wayfire/debug.hpp>
#include <wayfire/output-layout.hpp>
#include <wayfire/signal-definitions.hpp>
#include <wayfire/workspace-manager.hpp>

using CfgSection = std::shared_ptr<wf::config::section_t>;

template <typename T>
using CfgOption = std::shared_ptr<wf::config::option_t<T>>;

/// Temporary string buffer. Contents are invalid after any next function call.
static std::string string_buf;

inline constexpr wf_Geometry wrap_geo(wf::geometry_t geo) {
    return {geo.x, geo.y, geo.width, geo.height};
}

inline constexpr wf::geometry_t unwrap_geo(wf_Geometry geo) {
    return {geo.x, geo.y, geo.width, geo.height};
}

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

void wf_signal_subscribe(void *object_, const char *signal_) {
    string_buf = signal_;
    auto object = static_cast<wf::object_base_t *>(object_);

    wf_lua::get_plugin()->signal_subscribe(object, string_buf);
}

void wf_signal_unsubscribe(void *object_, const char *signal_) {
    const auto object = static_cast<wf::object_base_t *>(object_);

    wf_lua::get_plugin()->signal_unsubscribe(object, signal_);
}

wf_Output *wf_get_next_output(wf_Output *prev) {
    const auto &outputs = wf::get_core().output_layout;
    return (wf_Output *)outputs->get_next_output((wf::output_t *)prev);
}

wf_View *wf_get_signaled_view(void *sig_data) {
    return (wf_View *)wf::get_signaled_view((wf::signal_data_t *)sig_data)
        .get();
}

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

wf_Geometry wf_View_get_wm_geometry(wf_View *view) {
    return wrap_geo(((wf::view_interface_t *)view)->get_wm_geometry());
}
wf_Geometry wf_View_get_output_geometry(wf_View *view) {
    return wrap_geo(((wf::view_interface_t *)view)->get_output_geometry());
}
wf_Geometry wf_View_get_bounding_box(wf_View *view) {
    return wrap_geo(((wf::view_interface_t *)view)->get_bounding_box());
}

wf_Output *wf_View_get_output(wf_View *view) {
    return (wf_Output *)((wf::view_interface_t *)view)->get_output();
}

void wf_View_set_geometry(wf_View *view, wf_Geometry geo) {
    ((wf::view_interface_t *)view)->set_geometry(unwrap_geo(geo));
}

wf_Geometry wf_Output_get_workarea(wf_Output *output) {
    return wrap_geo(((wf::output_t *)output)->workspace->get_workarea());
}
}
