#include "wf-lua.hpp"

#include <wayfire/debug.hpp>
#include <wayfire/singleton-plugin.hpp>

namespace wf_lua {
static nonstd::observer_ptr<WFLua> plugin;

nonstd::observer_ptr<WFLua> get_plugin() { return plugin; }
} // namespace wf_lua

void WFLua::notify_signal_event(
    nonstd::observer_ptr<wf::signal_provider_t> object, const char *signal,
    wf::signal_data_t *data) const {
    event_callback(object.get(), WF_EVENT_TYPE_SIGNAL, signal, data);
}

void WFLua::register_event_callback(const wf_EventCallback callback) {
    assert(!event_callback);
    event_callback = callback;
}

struct LifetimeTracker : public wf::custom_data_t {
    wf::object_base_t *obj;
    LifetimeTracker(wf::object_base_t *obj) : obj(obj) {}
    virtual ~LifetimeTracker() {
        if (obj)
            wf_lua::get_plugin()->on_emitter_destroyed(obj);
    }
};

void WFLua::signal_subscribe(wf::object_base_t *object, std::string signal) {
    auto obj_entry = active_listeners.find(object);
    if (obj_entry == active_listeners.end()) {

        // Listen for the emitter's destruction.
        assert(!object->has_data<LifetimeTracker>());
        object->store_data(std::make_unique<LifetimeTracker>(object));

        obj_entry =
            active_listeners
                .emplace(object,
                         std::map<std::string, wf::signal_connection_t>())
                .first;
    }

    if (obj_entry->second.find(signal) != obj_entry->second.end())
        LOGE("Subscribed to signal more than once!");

    const auto s =
        &obj_entry->second
             .emplace(signal,
                      [=](wf::signal_data_t *data) {
                          notify_signal_event(object, signal.c_str(), data);
                      })
             .first->second;

    object->connect_signal(signal, s);
}

void WFLua::signal_unsubscribe(wf::object_base_t *object,
                               const std::string &signal) {
    const auto obj_entry = active_listeners.find(object);
    if (obj_entry == active_listeners.end()) {
        LOGE("Unsubscribed from non-subscribed object!");
        return;
    }

    const auto sig_entry = obj_entry->second.find(signal);
    if (sig_entry == obj_entry->second.end()) {
        LOGE("Unsubscribed from non-subscribed signal!");
        return;
    }

    obj_entry->second.erase(sig_entry);
    if (obj_entry->second.empty()) {
        active_listeners.erase(obj_entry);
        auto tracker = object->release_data<LifetimeTracker>();
        tracker->obj = nullptr;
        // tracker dies here
    }
}

void WFLua::on_emitter_destroyed(wf::object_base_t *object) {
    active_listeners.erase(object);
    event_callback(object, WF_EVENT_TYPE_EMITTER_DESTROYED, nullptr, nullptr);
}

WFLua::WFLua() {
    LOGI("Hello world!");

    wf_lua::plugin = this;

    L = luaL_newstate();
    luaL_openlibs(L);

    luaL_dostring(L, "package.path = package.path .. ';" LUA_RUNTIME "/?.lua'");

    if (luaL_loadfile(L, "init.lua"))
        LOGE("Failed to load init file: ", lua_tostring(L, -1));

    LOGI("RUNNING INIT");
    if (lua_pcall(L, 0, LUA_MULTRET, 0))
        LOGE("Failed to run init file: ", lua_tostring(L, -1));
    LOGI("DONE");
}

WFLua::~WFLua() {
    LOGI("Goodbye!");

    lua_close(L);
}

DECLARE_WAYFIRE_PLUGIN((wf::singleton_plugin_t<WFLua>));
