# SPDX-FileCopyrightText: Jean-Luc Deprez <https://github.com/spangaer>
# SPDX-License-Identifier: MIT

set shell := ["bash", "-euo", "pipefail", "-c"]

# the testbed's recipes, e.g. just testbed::vm-up. Its settings, like vm=build, can't be set from
# here, so for those run just in testbed/, e.g. cd testbed && just vm=build vm-up
mod testbed

# list recipes
default:
    @just --list --list-submodules

# devcontainer setup, run on create; safe to rerun
setup:
    just testbed::setup

# lint licensing and all shell scripts; git's file list and reuse skip what .gitignore excludes,
# like .local/
lint:
    reuse lint
    git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 shellcheck -x

# add an SPDX header to files without one, skipping those REUSE.toml covers; use this, not
# reuse annotate --recursive
annotate license="MIT" holder="Jean-Luc Deprez <https://github.com/spangaer>":
    .reuse/annotate.sh {{ quote(license) }} {{ quote(holder) }}
