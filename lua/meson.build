wf_h = run_command('cat', files('../src/wf.h')).stdout().strip()

configure_file(
	configuration: {'WF_H': wf_h},
	input: 'wf.lua.in',
	output: 'wf.lua',
	install: true,
	install_dir: lua_runtime_dir)

install_subdir('wf', install_dir: lua_runtime_dir)
