typedef enum {
    WFLUA_LOGLVL_ERR,
    WFLUA_LOGLVL_WARN,
    WFLUA_LOGLVL_DEBUG,
} wflua_LogLvl;

void wflua_log(wflua_LogLvl lvl, const char *msg);

typedef enum {
    WFLUA_EVENT_TYPE_SIGNAL,
    WFLUA_EVENT_TYPE_EMITTER_DESTROYED,
} wflua_EventType;

typedef void (*wflua_EventCallback)(void *emitter, wflua_EventType event_type,
                                    const char *signal, void *data);

void wflua_register_event_callback(const wflua_EventCallback callback);

void wflua_lifetime_subscribe(void *object);
void wflua_lifetime_unsubscribe(void *object);

void wflua_signal_subscribe(void *object, const char *signal);
void wflua_signal_unsubscribe(void *object, const char *signal);
void wflua_signal_unsubscribe_all(void *object);
