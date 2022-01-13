# TODO: make this file more portable / ditch make entirely once zig build
#       supports building with 3rd party c++ compilers.

# Tabs are stupid and portable makefiles take a lot of work :(
# Use a leading space instead of a leading tab. (GNU extension)
.RECIPEPREFIX := $(.RECIPEPREFIX) #

CXX         := clang++
CXX_FLAGS   := -Wall -Wextra -Werror -O3 -g -std=c++17
CXX_OBJ_DIR := zig-cache/cxx

plugin_sources := src/wf.cpp src/wf-plugin.cpp
plugin_objects := $(patsubst %.cpp,$(CXX_OBJ_DIR)/%.o,$(plugin_sources))

.PHONY: plugin_objs
plugin_objs: $(dir $(plugin_objects)) $(plugin_objects)

# Prepare output directories.
# (sort for removing duplicates in the list of dirs)
$(sort $(dir $(plugin_objects))):
    mkdir -p $@

# Build objs.
$(plugin_objects): $(CXX_OBJ_DIR)/%.o: %.cpp
    $(CXX) \
        `pkg-config --cflags wayfire` \
        -fPIC \
        -DWLR_USE_UNSTABLE -DWAYFIRE_PLUGIN \
        $(CXX_FLAGS) \
        -c $< -o $@
