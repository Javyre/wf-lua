#ifndef WF_LUA_HPP
#define WF_LUA_HPP

#include <map>

#include <lua.hpp>
#include <wayfire/nonstd/observer_ptr.h>
#include <wayfire/object.hpp>
#include <wayfire/plugin.hpp>

extern "C" {
#include "wf.h"
}

class WFLua;
namespace wf_lua {
nonstd::observer_ptr<WFLua> get_plugin();
};

class WFLua {
  private:
    /// The main lua state handle.
    lua_State *L;

    /// This callback is used for most C -> lua communication.
    wf_EventCallback event_callback = 0;

    /// The active signal listeners.
    std::map<nonstd::observer_ptr<wf::signal_provider_t>,
             std::map<std::string, wf::signal_connection_t>>
        active_listeners;

    /// Notify the event callback of an emitted signal.
    void notify_signal_event(nonstd::observer_ptr<wf::signal_provider_t> object,
                             const char *signal, wf::signal_data_t *data) const;

  public:
    WFLua();
    ~WFLua();

    /// Register the lua event callback.
    void register_event_callback(const wf_EventCallback callback);

    /// Start listening for an object's signal.
    void signal_subscribe(wf::object_base_t *object, std::string signal);

    /// Stop listening for an object's signal.
    void signal_unsubscribe(wf::object_base_t *object,
                            const std::string &signal);

    /// Handle the emitter object being destroyed.
    void on_emitter_destroyed(wf::object_base_t *object);
};

#endif // ifndef WF_LUA_HPP
