typedef enum {
    WF_OK = 0,
    WF_INVALID_OPTION_VALUE,
    WF_INVALID_OPTION_SECTION,
    WF_INVALID_OPTION,
} wf_Error;

typedef enum {
    WF_EVENT_TYPE_SIGNAL,
    WF_EVENT_TYPE_SIGNAL_DISCONNECTED
} wf_EventType;

typedef void (*wf_EventCallback)(void *emitter, wf_EventType event_type,
                                 const char *signal, void *data);

wf_Error wf_set_option_str(const char *section, const char *option,
                           const char *val);

void wf_register_event_callback(const wf_EventCallback callback);

void wf_signal_subscribe(void *object, const char *signal);
void wf_signal_unsubscribe(void *object, const char *signal);

typedef struct wf_Output wf_Output;
wf_Output *wf_get_next_output(wf_Output *prev);

typedef struct wf_View wf_View;
wf_View *wf_get_signaled_view(void *sig_data);

const char *wf_View_to_string(wf_View *view);
const char *wf_View_get_title(wf_View *view);
const char *wf_View_get_app_id(wf_View *view);

const char *wf_Output_to_string(wf_Output *output);
