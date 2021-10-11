plugin_src = files([
    'wf-lua.cpp',
    'wf.cpp',
])

all_src += plugin_src
all_src += files([
    'wf-lua.hpp',
    'wf.h',
])

wf_lua = shared_module('wf-lua', plugin_src,
    dependencies: [wayfire, wlroots, luajit],
    install: true, 
    install_dir: get_option('libdir') / 'wayfire')
