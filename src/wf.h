// NOTE: In order to stay as usable and portable as possible. We don't want to
// use any preprocessor macros in this file.
//
// Because of this we can't use stdbool.h since we can't  include any headers.
// We use _Bool which is a keyword in C99.

typedef enum {
    WF_OK = 0,
    WF_INVALID_OPTION_VALUE,
    WF_INVALID_OPTION_SECTION,
    WF_INVALID_OPTION,
} wf_Error;

wf_Error wf_set_option_str(const char *section, const char *option,
                           const char *val);

typedef void (*wf_LifetimeCallback)(void *emitter, void *data);

void wf_lifetime_subscribe(void *object, wf_LifetimeCallback cb, void *data);
void wf_lifetime_unsubscribe(void *object, wf_LifetimeCallback cb);

typedef void (*wf_SignalCallback)(void *signal_data, void *data1, void *data2);
typedef struct wf_SignalConnection wf_SignalConnection;

wf_SignalConnection *wf_create_signal_connection(wf_SignalCallback cb,
                                                 void *data1, void *data2);
void wf_destroy_signal_connection(wf_SignalConnection *conn);

void wf_signal_subscribe(void *object, const char *signal,
                         wf_SignalConnection *handler);
void wf_signal_unsubscribe(void *object, wf_SignalConnection *handler);

typedef struct {
    int x, y;
    int width, height;
} wf_Geometry;

typedef struct {
    int width, height;
} wf_Dimensions;

typedef struct {
    double x, y;
} wf_Pointf;

typedef struct wf_Output wf_Output;
wf_Output *wf_get_next_output(wf_Output *prev);

typedef struct wf_View wf_View;
wf_View *wf_get_signaled_view(void *sig_data);

const char *wf_View_to_string(wf_View *view);
const char *wf_View_get_title(wf_View *view);
const char *wf_View_get_app_id(wf_View *view);
wf_Geometry wf_View_get_wm_geometry(wf_View *view);
wf_Geometry wf_View_get_output_geometry(wf_View *view);
wf_Geometry wf_View_get_bounding_box(wf_View *view);
wf_Output *wf_View_get_output(wf_View *view);
void wf_View_set_geometry(wf_View *view, wf_Geometry geo);

const char *wf_Output_to_string(wf_Output *output);
wf_Dimensions wf_Output_get_screen_size(wf_Output *output);
wf_Geometry wf_Output_get_relative_geometry(wf_Output *output);
wf_Geometry wf_Output_get_layout_geometry(wf_Output *output);
void wf_Output_ensure_pointer(wf_Output *output, _Bool center);
wf_Pointf wf_Output_get_cursor_position(wf_Output *output);
// TODO: make binding for call_plugin(). This would unlock a lot of wflua
// usecases. (e.g. activate expo from a lua script).
wf_View *wf_Output_get_top_view(wf_Output *output);
wf_View *wf_Output_get_active_view(wf_Output *output);
void wf_Output_focus_view(wf_Output *output, wf_View *v, _Bool raise);
_Bool wf_Output_ensure_visible(wf_Output *output, wf_View *view);
wf_Geometry wf_Output_get_workarea(wf_Output *output);

typedef struct wf_Core wf_Core;
wf_Core *wf_get_core();

const char *wf_Core_to_string(wf_Core *core);
void wf_Core_set_cursor(wf_Core *core, const char *name);
void wf_Core_unhide_cursor(wf_Core *core);
void wf_Core_hide_cursor(wf_Core *core);
void wf_Core_warp_cursor(wf_Core *core, wf_Pointf position);
wf_Pointf wf_Core_get_cursor_position(wf_Core *core);
wf_View *wf_Core_get_cursor_focus_view(wf_Core *core);
wf_View *wf_Core_get_touch_focus_view(wf_Core *core);
wf_View *wf_Core_get_view_at(wf_Core *core, wf_Pointf point);
// TODO: port wf_Output_get_all_views(wf_Core *core)
void wf_Core_set_active_view(wf_Core *core, wf_View *v);
void wf_Core_focus_view(wf_Core *core, wf_View *win);
void wf_Core_focus_output(wf_Core *core, wf_Output *o);
wf_Output *wf_Core_get_active_output(wf_Core *core);
void wf_Core_move_view_to_output(wf_Core *core, wf_View *v,
                                 wf_Output *new_output, _Bool reconfigure);
const char *wf_Core_get_wayland_display(wf_Core *core);
const char *wf_Core_get_xwayland_display(wf_Core *core);
int wf_Core_run(wf_Core *core, const char *command);
void wf_Core_shutdown(wf_Core *core);
