// "in-house" wayfire C bindings. Plugin declaration.
// Link this into the binary only if it is meant as a plugin.

#include <wayfire/plugin.hpp>

extern "C" {
// These are expected to be implemented on the <other-lang>-side.
void *plugin_init();
void plugin_fini(void *);
}

struct GenericPlugin final : public wf::plugin_interface_t {
    void *plugin_state = nullptr;

  public:
    void init() noexcept override { plugin_state = plugin_init(); }
    void fini() noexcept override { plugin_fini(plugin_state); }
};

extern "C" {
wf::plugin_interface_t *newInstance() noexcept { return new GenericPlugin; }

uint32_t getWayfireVersion() noexcept { return WAYFIRE_API_ABI_VERSION; }
}
