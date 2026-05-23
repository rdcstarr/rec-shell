# shellcheck shell=bash
#
# DDEV smart commands. Inside a ddev project, common dev tools run in the
# container (`ddev exec ...`); elsewhere they fall through to the host binary.
# Defined only when ddev is installed, so servers without ddev keep plain
# commands. Disable with: REC_DISABLED_MODULES="ddev"

# True if the current directory (or its immediate parent) is a ddev project.
_in_ddev_project() {
  [ -f ".ddev/config.yaml" ] || [ -f "../.ddev/config.yaml" ]
}

if rec_have ddev; then
  # _ddev_wrap CMD ARGS...  -> `ddev exec CMD ARGS` in a project, else host CMD.
  # `command` avoids recursing back into these wrapper functions.
  _ddev_wrap() {
    local _ddw_cmd="$1"
    shift
    if _in_ddev_project; then
      ddev exec "$_ddw_cmd" "$@"
    else
      command "$_ddw_cmd" "$@"
    fi
  }

  php() { _ddev_wrap php "$@"; }
  composer() { _ddev_wrap composer "$@"; }
  npm() { _ddev_wrap npm "$@"; }
  yarn() { _ddev_wrap yarn "$@"; }
  node() { _ddev_wrap node "$@"; }
  wp() { _ddev_wrap wp "$@"; }

  # artisan is special: `ddev artisan` in a project, `php artisan` on the host.
  artisan() {
    if _in_ddev_project; then
      ddev artisan "$@"
    else
      command php artisan "$@"
    fi
  }
fi
