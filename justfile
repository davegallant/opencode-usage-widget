# OpenCode Usage widget tasks
# Recipes delegate to the shell scripts so there is one source of truth for
# the zip excludes (build.sh) and the symlink/cache/restart dance (install.sh).

default: build

# Build a distributable .plasmoid into dist/
build:
    ./build.sh

# Symlink package/ into Plasma, clear the QML cache, restart plasmashell
install:
    ./install.sh
