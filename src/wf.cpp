using _Bool = bool;
extern "C" {
#include "wf.h"
}

#include <wayfire/config/compound-option.hpp>
#include <wayfire/config/config-manager.hpp>
#include <wayfire/core.hpp>
#include <wayfire/debug.hpp>
#include <wayfire/output-layout.hpp>
#include <wayfire/signal-definitions.hpp>
#include <wayfire/workspace-manager.hpp>

#include <unordered_map>

/// Temporary string buffer. Contents are invalid after any next function call.
static std::string string_buf;

inline constexpr wf_Geometry wrap_geo(wf::geometry_t geo) {
    return {geo.x, geo.y, geo.width, geo.height};
}
inline constexpr wf::geometry_t unwrap_geo(wf_Geometry geo) {
    return {geo.x, geo.y, geo.width, geo.height};
}

inline constexpr wf_Dimensions wrap_dims(wf::dimensions_t dims) {
    return {dims.width, dims.height};
}
inline constexpr wf::dimensions_t unwrap_dims(wf_Dimensions dims) {
    return {dims.width, dims.height};
}

inline constexpr wf_Pointf wrap_pointf(wf::pointf_t point) {
    return {point.x, point.y};
}
inline constexpr wf::pointf_t unwrap_pointf(wf_Pointf point) {
    return {point.x, point.y};
}

inline constexpr wf_View *wrap_view(wf::view_interface_t *view) {
    return (wf_View *)view;
}
inline constexpr wf_View *wrap_view(wayfire_view view) {
    return (wf_View *)view.get();
}
inline constexpr wf::view_interface_t *unwrap_view(wf_View *view) {
    return (wf::view_interface_t *)view;
}

inline constexpr wf_Output *wrap_output(wf::output_t *output) {
    return (wf_Output *)output;
}
inline constexpr wf::output_t *unwrap_output(wf_Output *output) {
    return (wf::output_t *)output;
}

inline constexpr wf_Core *wrap_core(wf::compositor_core_t *core) {
    return (wf_Core *)core;
}
inline constexpr wf::compositor_core_t *unwrap_core(wf_Core *core) {
    return (wf::compositor_core_t *)core;
}

inline constexpr wf_OutputLayout *
wrap_output_layout(wf::output_layout_t *layout) {
    return (wf_OutputLayout *)layout;
}
inline constexpr wf::output_layout_t *
unwrap_output_layout(wf_OutputLayout *layout) {
    return (wf::output_layout_t *)layout;
}

struct LifetimeTracker : public wf::custom_data_t {
    struct CallbackPair {
        wf_LifetimeCallback callback;
        void *data;
    };

    wf::object_base_t *obj;                ///< Tracked object
    std::vector<CallbackPair> callbacks{}; ///< Callbacks

    LifetimeTracker(wf::object_base_t *obj) : obj(obj) {}
    virtual ~LifetimeTracker() {
        for (auto cb : callbacks)
            cb.callback(obj, cb.data);
    }

    void add_callback(wf_LifetimeCallback cb, void *data) {
        callbacks.push_back({cb, data});
    }
    void remove_callback(wf_LifetimeCallback cb) {
        for (auto i = callbacks.rbegin(); i < callbacks.rend(); i++) {
            if (i->callback == cb) {
                callbacks.erase(i.base());
                return;
            }
        }

        LOGE("Cannnot find callback to unsubscribe.");
    }
};

/// Global signal connection table.
static std::unordered_map<wf_SignalCallback, wf::signal_connection_t>
    signal_callbacks;

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

void wf_lifetime_subscribe(void *object_, wf_LifetimeCallback cb, void *data) {
    auto object = static_cast<wf::object_base_t *>(object_);
    auto tracker = object->get_data<LifetimeTracker>();
    if (!tracker) {
        auto owned_tracker = std::make_unique<LifetimeTracker>(object);
        tracker = owned_tracker.get();
        object->store_data(std::move(owned_tracker));
    }

    tracker->add_callback(cb, data);
}

void wf_lifetime_unsubscribe(void *object_, wf_LifetimeCallback cb) {
    auto object = static_cast<wf::object_base_t *>(object_);
    auto tracker = object->get_data<LifetimeTracker>();
    if (!tracker) {
        LOGE("No lifetime tracker to unsubcribe from.");
        return;
    }

    tracker->remove_callback(cb);
    if (tracker->callbacks.empty())
        object->erase_data<LifetimeTracker>();
}

wf_SignalConnection *wf_create_signal_connection(wf_SignalCallback cb,
                                                 void *data1, void *data2) {
    return (wf_SignalConnection *)(new wf::signal_connection_t(
        [=](auto *sig_data) { cb((void *)sig_data, data1, data2); }));
}
void wf_destroy_signal_connection(wf_SignalConnection *conn) {
    delete (wf::signal_connection_t *)conn;
}
void wf_signal_subscribe(void *emitter_, const char *signal_,
                         wf_SignalConnection *conn) {
    string_buf = signal_;
    auto emitter = static_cast<wf::signal_provider_t *>(emitter_);

    emitter->connect_signal(string_buf, (wf::signal_connection_t *)conn);
}

void wf_signal_unsubscribe(void *emitter_, wf_SignalConnection *conn) {
    const auto emitter = static_cast<wf::signal_provider_t *>(emitter_);

    emitter->disconnect_signal((wf::signal_connection_t *)conn);
}

wf_View *wf_get_signaled_view(void *sig_data) {
    return wrap_view(wf::get_signaled_view((wf::signal_data_t *)sig_data));
}

wf_Output *wf_get_signaled_output(void *sig_data) {
    return wrap_output(wf::get_signaled_output((wf::signal_data_t *)sig_data));
}

// TODO: no need for this to be a macro.
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
    return wrap_geo(unwrap_view(view)->get_wm_geometry());
}
wf_Geometry wf_View_get_output_geometry(wf_View *view) {
    return wrap_geo(unwrap_view(view)->get_output_geometry());
}
wf_Geometry wf_View_get_bounding_box(wf_View *view) {
    return wrap_geo(unwrap_view(view)->get_bounding_box());
}

wf_Output *wf_View_get_output(wf_View *view) {
    return wrap_output(unwrap_view(view)->get_output());
}

void wf_View_set_geometry(wf_View *view, wf_Geometry geo) {
    unwrap_view(view)->set_geometry(unwrap_geo(geo));
}

wf_Dimensions wf_Output_get_screen_size(wf_Output *output) {
    return wrap_dims(unwrap_output(output)->get_screen_size());
}
wf_Geometry wf_Output_get_relative_geometry(wf_Output *output) {
    return wrap_geo(unwrap_output(output)->get_relative_geometry());
}
wf_Geometry wf_Output_get_layout_geometry(wf_Output *output) {
    return wrap_geo(unwrap_output(output)->get_layout_geometry());
}
void wf_Output_ensure_pointer(wf_Output *output, bool center) {
    unwrap_output(output)->ensure_pointer(center);
}
wf_Pointf wf_Output_get_cursor_position(wf_Output *output) {
    return wrap_pointf(unwrap_output(output)->get_cursor_position());
}
wf_View *wf_Output_get_top_view(wf_Output *output) {
    return wrap_view(unwrap_output(output)->get_top_view());
}
wf_View *wf_Output_get_active_view(wf_Output *output) {
    return wrap_view(unwrap_output(output)->get_active_view());
}
void wf_Output_focus_view(wf_Output *output, wf_View *v, bool raise) {
    unwrap_output(output)->focus_view(unwrap_view(v), raise);
}
bool wf_Output_ensure_visible(wf_Output *output, wf_View *view) {
    return unwrap_output(output)->ensure_visible(unwrap_view(view));
}

// NOTE: this is not directly an output method. It is exposed on wf_Output for
// simplicity.
wf_Geometry wf_Output_get_workarea(wf_Output *output) {
    return wrap_geo(unwrap_output(output)->workspace->get_workarea());
}

wf_Core *wf_get_core() { return wrap_core(&wf::get_core()); }

const char *wf_Core_to_string(wf_Core *core) {
    string_buf = unwrap_core(core)->to_string();
    return string_buf.c_str();
}
void wf_Core_set_cursor(wf_Core *core, const char *name) {
    string_buf = name;
    unwrap_core(core)->set_cursor(string_buf);
}
void wf_Core_unhide_cursor(wf_Core *core) {
    unwrap_core(core)->unhide_cursor();
}
void wf_Core_hide_cursor(wf_Core *core) { unwrap_core(core)->hide_cursor(); }
void wf_Core_warp_cursor(wf_Core *core, wf_Pointf position) {
    unwrap_core(core)->warp_cursor(unwrap_pointf(position));
}
wf_Pointf wf_Core_get_cursor_position(wf_Core *core) {
    return wrap_pointf(unwrap_core(core)->get_cursor_position());
}
wf_View *wf_Core_get_cursor_focus_view(wf_Core *core) {
    return wrap_view(unwrap_core(core)->get_cursor_focus_view());
}
wf_View *wf_Core_get_touch_focus_view(wf_Core *core) {
    return wrap_view(unwrap_core(core)->get_touch_focus_view());
}
wf_View *wf_Core_get_view_at(wf_Core *core, wf_Pointf point) {
    return wrap_view(unwrap_core(core)->get_view_at(unwrap_pointf(point)));
}
void wf_Core_set_active_view(wf_Core *core, wf_View *v) {
    unwrap_core(core)->set_active_view(unwrap_view(v));
}
void wf_Core_focus_view(wf_Core *core, wf_View *win) {
    unwrap_core(core)->focus_view(unwrap_view(win));
}
void wf_Core_focus_output(wf_Core *core, wf_Output *o) {
    unwrap_core(core)->focus_output(unwrap_output(o));
}
wf_Output *wf_Core_get_active_output(wf_Core *core) {
    return wrap_output(unwrap_core(core)->get_active_output());
}
void wf_Core_move_view_to_output(wf_Core *core, wf_View *v,
                                 wf_Output *new_output, bool reconfigure) {
    unwrap_core(core)->move_view_to_output(
        unwrap_view(v), unwrap_output(new_output), reconfigure);
}
const char *wf_Core_get_wayland_display(wf_Core *core) {
    // the std::string wayland_display should have the lifetime of core. So
    // returning the c_str buffer should be fine.
    return unwrap_core(core)->wayland_display.c_str();
}
const char *wf_Core_get_xwayland_display(wf_Core *core) {
    string_buf = unwrap_core(core)->get_xwayland_display();
    return string_buf.c_str();
}
int wf_Core_run(wf_Core *core, const char *command) {
    string_buf = command;
    return unwrap_core(core)->run(string_buf);
}
void wf_Core_shutdown(wf_Core *core) { unwrap_core(core)->shutdown(); }
wf_OutputLayout *wf_Core_get_output_layout(wf_Core *core) {
    return wrap_output_layout(unwrap_core(core)->output_layout.get());
}

wf_Output *wf_OutputLayout_get_output_at(wf_OutputLayout *layout, int x,
                                         int y) {
    return wrap_output(unwrap_output_layout(layout)->get_output_at(x, y));
}
wf_Output *wf_OutputLayout_get_output_coords_at(wf_OutputLayout *layout,
                                                wf_Pointf origin,
                                                wf_Pointf *closest) {
    wf::pointf_t closest_cpp;
    const auto ret =
        wrap_output(unwrap_output_layout(layout)->get_output_coords_at(
            unwrap_pointf(origin), closest_cpp));
    closest->x = closest_cpp.x;
    closest->y = closest_cpp.y;
    return ret;
}
unsigned int wf_OutputLayout_get_num_outputs(wf_OutputLayout *layout) {
    return unwrap_output_layout(layout)->get_num_outputs();
}
wf_Output *wf_OutputLayout_get_next_output(wf_OutputLayout *layout,
                                           wf_Output *prev) {
    return wrap_output(
        unwrap_output_layout(layout)->get_next_output(unwrap_output(prev)));
}
wf_Output *wf_OutputLayout_find_output(wf_OutputLayout *layout,
                                       const char *name) {
    string_buf = name;
    return wrap_output(unwrap_output_layout(layout)->find_output(string_buf));
}
}
