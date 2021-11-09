wf_h = run_command('cat', files('../src/wf.h')).stdout().strip()

configure_file(
	configuration: {'WF_H': wf_h},
	input: 'wf/wf_h.lua.in',
	output: 'wf_h.lua',
	install: true,
	install_dir: lua_runtime_dir / 'wf')

install_data('wf.lua', install_dir: lua_runtime_dir)
install_subdir('wf', install_dir: lua_runtime_dir, exclude_files: ['wf_h.lua.in'])
