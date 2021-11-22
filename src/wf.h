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
wf_Geometry wf_Output_get_workarea(wf_Output *output);
