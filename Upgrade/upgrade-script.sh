#!/bin/bash
#
# Upgrade-pack for CO2MPAS ${VERSION_FILE_CHECK%.ver} --> $NEW_VERSION
#
# SYNTAX:
#     $prog [options]
# OPTIONS:
#   -d|--debug                      like --keep-going, but break into a debug shell to fix problem
#   -h|--help                       display this message
#   --inflate-only                  extract pack-files and exit
#   -k|--keep-going:                continue working on errors (see also to --debug)
#   --keep-inflated                 do not clean up in  flated temporary dir
#   -n|--dry-run:                   pretend actions executed (pack-files always inflated)
#   --old-aio-version <VERSION>     don't ask user for it (used only if cannot locate AIO's version-file).
#   -v|--verbose:                   increase verbosity (eg -vvv prints commands as executed)
#   -y|--yes:                       answer all questions with yes (no interactive)
#
# - Contains $WINPY_NPACKAGES new or updated python packages (wheels).
# - Files will be inflated under \$TMP folder ($INFLATE_DIR).
# - \$CMDPATH controls the execution path of all POSIX commands invoked.
# - All options have env-var counterparts (eg. --dry-run <--> \$DRY_RUN).
# - Config-variables: ${!CONF[@]} 
#

set -u  # fail on unset variables
set -E  # funcs inherit traps
#set -o pipefail  # code written &&  expects diffrently...
set -a  # export all, to facilitate --debug sub-shell

VERSION_FILE_CHECK="AIO-1.7.3*.ver"
NEW_VERSION=
INFLATE_DIR=
declare -i WINPY_NPACKAGES=

prog="$0"
declare -i VERBOSE="${VERBOSE:-0}"
declare -A CONF=(  # Wrapped in an array not to type var-names twice.
    [VERBOSE]="$VERBOSE"
    [AIODIR]="${AIODIR:=}"
    [WINPYDIR]="${WINPYDIR:=}"
    [DRY_RUN]="${DRY_RUN:=}"
    [KEEP_GOING]="${KEEP_GOING:=}"
    [DEBUG]="${DEBUG:=}"
    [ALL_YES]="${ALL_YES:=}"
    [INFLATE_ONLY]="${INFLATE_ONLY:=}"
    [KEEP_INFLATED]="${KEEP_INFLATED:=}"
    [OLD_AIO_VERSION]="${OLD_AIO_VERSION:=}"
    [PIP_INSTALL_OPTS]="${PIP_INSTALL_OPTS:=--no-index --no-dependencies}"
)

exec 3>/dev/null  # &3 used for redirecting stuff to log.

## ALL CMDS HERE
#  (remember to add them also in verbose/dry-run)
#
CONF_CMDS=(
    "${CMDPATH:=/usr/bin}"
    "${rm:=$CMDPATH/rm}"
    "${cat:=$CMDPATH/cat}"
    "${cp:=$CMDPATH/cp}"
    "${rsync:=$CMDPATH/rsync}"
    "${tee:=$CMDPATH/tee}"
    "${find:=$CMDPATH/find}"        # same filename in Windows path
    "${grep:=$CMDPATH/grep}"
    "${sed:=$CMDPATH/sed}"
    "${date:=$CMDPATH/date}"
    "${tput:=$CMDPATH/tput}"
    "${cygpath:=$CMDPATH/cygpath}"

    "${python:=$WINPYDIR/python}"
    "${pip:=$WINPYDIR/Scripts/pip}"

    ## Differentiate, not to --dry-run pack-files inflation.
    #
    "${infl_awk:=$CMDPATH/awk}"
    "${infl_tail:=$CMDPATH/tail}"
    "${infl_mkdir:=$CMDPATH/mkdir}" # that
    "${infl_tar:=$CMDPATH/tar}"
    "${infl_rm:=$CMDPATH/rm}"
)


####################################
# Cmdline parsing & validation.
####################################
#
get_help () {
    local -a help_lines
    ## Read as array (from https://unix.stackexchange.com/a/205073/156357)
    #  and remove the 2-char comment prefix.
    #
    mapfile -s2 -n20 help_lines < "$prog"
    HELP="${help_lines[@]#\# }"
    HELP_OPENING="${help_lines[0]#\# }"

    # Expand variables, from https://stackoverflow.com/a/27948896/548792
    #
    HELP=$(eval "echo \"$HELP\"")
    HELP_OPENING=$(eval "echo \"$HELP_OPENING\"")
}

BAD_OPTS= BAD_ARGS=
parse_opt () {
    SHIFTARGS=1
    case "$1" in
        (--inflate-only)
            INFLATE_ONLY=true
            KEEP_INFLATED=true
            ;;
        (--keep-inflated)
            KEEP_INFLATED=true
            ;;
        (--old-aio-version)
            if [ $# -lt 2 ]; then
                BAD_OPTS="$BAD_OPTS $1(version missing)"
            elif [ "${2#-}" != "$2" ]; then
                BAD_OPTS="$BAD_OPTS $1(followed by option $2)"
            else
                OLD_AIO_VERSION=$2
                SHIFTARGS=2
            fi
            ;;
        (-h|--help)
            echo "$HELP"
                set +x
            exit
            ;;
        (-k|--keep-going)
            KEEP_GOING=true
            ;;
        (-d|--debug)
            DEBUG=true
            ;;
        (-y|--yes)
            ALL_YES=true
            ;;
        (-n|--dry-run)
            DRY_RUN=true
            ;;
        (-v|--verbose)
            VERBOSE=$((VERBOSE + 1))
            ;;
        (-[a-z]?*)
            ## recursively parse '-vvn'`' opts.`
            #
            parse_opt "-${1:1:1}"
            parse_opt "-${1:2}"
            ;;
        (-*)
            echo "p$1p"
            BAD_OPTS="$BAD_OPTS $1"
            ;;
        (*)
            BAD_ARGS="$BAD_ARGS $1"
            ;;
    esac
}


pargs_cmdline_args () {
    while [ $# -ne 0 ]; do
        parse_opt "$@"
        shift $SHIFTARGS
    done
    if [ -n "$BAD_OPTS$BAD_ARGS" ]; then
        die "command received invalid options or arguments:" \
            "\n  bad options: $BAD_OPTS" \
            "\n  unexpected args: $BAD_ARGS\nAborting.\n\n$HELP"
    fi

    if [ -n "$DRY_RUN" ]; then
        DRY_RUN="PRETEND "
        info "${DRY_RUN}actions..."
        cp="echo $DRY_RUN$cp"
        rsync="$rsync --dry-run"
        rm="echo $DRY_RUN$rm"
        pip="echo $DRY_RUN$pip"
        tee="echo $DRY_RUN$tee"
        sed="echo $DRY_RUN$sed"
    fi

    if [ $VERBOSE -gt 0 ]; then
        local confdump=

        rm="$rm -v"
        cp="$cp -v"
        rsync="$rsync -v"
        infl_rm="$rm -v"
        infl_mkdir="$infl_mkdir -v"
        infl_tar="$infl_tar -v"
        exec 3>&2

       if [ $VERBOSE -gt 1 ]; then
            confdump=$( set -o posix; set )
            (set -o posix; set)
            pip="$pip -vv"
            rsync="$rsync -v"
            if [ $VERBOSE -gt 2 ]; then
                set -x
            fi
        else
            confdump="- configuration: $(declare -p CONF) \n- command paths: ${CONF_CMDS[@]}"
        fi

        log "$confdump\n"
    fi
}


####################################
# Logging & Errors utils
####################################
#
## Logging from: https://natelandau.com/bash-scripting-utilities/
# Only those attributes below work in AIO-console.
#
bold=$($tput bold)
red=$($tput setaf 1)
#red=$($tput setaf 6)    # redder
green=$($tput setaf 2)   # hard to tell from cyan/blue
tan=$($tput setaf 3)     # with bold only
blue=$($tput setaf 4)
reset=$($tput sgr0)
log () {
    echo -e "$prog:" "$@" >&2
}
debug () {
    if [ $VERBOSE -gt 0 ]; then
        log "$@"
    fi
}
info () {
    log $bold$blue"$@"$reset
}
notice () {
    log $bold$green"$@"$reset
}
warn () {
    log WARN: $bold$tan"$@"$reset
}
error () {
    log ERR: $bold$red"$@"$reset
}
die () {
    log FATAL $bold$red"$@"$reset
    exit 1
}
err_report () {
    ## Adapted from: https://stackoverflow.com/a/185900/548792
    local err="aborted in line $1: ${2:-unspecified error}"
    err+="\n  stack: ${FUNCNAME[@]:1}"
    if [ -n "$DEBUG" ]; then
        local banner="$bold${green}Broke into DEBUG shell.
  - All functions and variables have been iherited.
  - Exit when done to continue.
  - Exit with non-zero status to abort program).$reset"

        error "$err"
        # From: https://stackoverflow.com/a/7193037/548792
        if ! bash --rcfile <(echo "export PS1='\[\033[33m\][$prog: line $1][\033[0m\] > ' &&  echo -e \"\$banner\""); then
            die "Aborted by debug shell."
        fi
    elif [ -n "$KEEP_GOING" ]; then
        error "error in line $1:${2:-unspecified error}$green\n  ...but KEEP GOING."
    else
        die "$err\n  (relaunch with -v(vv) and ask for help)"
    fi
}
trap 'err_report $LINENO  "$BASH_COMMAND"' ERR


####################################
# Generic utils
####################################
#
in_str() {
    ## $ in_str 'b' 'abc && echo ok
    #  ok
    #  from https://stackoverflow.com/a/20460402/548792
    [ -z "${2##*$1*}" ];
}
yesorno() {
    local resp default_key="$1" default_ret="$2"  msg="${@:3}"
    while true; do
        echo "$msg" >&2
        while read resp; do
            [ -z "$resp" ] && echo "$default_key" && return $default_ret
            [ ${#resp} -ne 1 ] && continue
            in_str $resp 'yY' && return 0
            in_str $resp 'nN' && return 1
        done
    done
}


####################################
# Upgrade AIO functionality
####################################
#
prompt_for_abort() {
    if [ "$OLD_AIO_VERSION" = "$NEW_VERSION" ]; then
        SCRIPT_ACTION="RE-INSTALL into '$AIODIR', version $OLD_AIO_VERSION"
    else
        SCRIPT_ACTION="UPGRADE '$AIODIR', from version $OLD_AIO_VERSION --> $NEW_VERSION"
    fi

    if [ -z "$ALL_YES" ]; then
        read -rs -p "${green}Ready to $SCRIPT_ACTION
  Press [Enter] to continue, or [Ctrl+C] to cancel? $reset"
        echo >&2
    else
        notice "Proceeding to $SCRIPT_ACTION..."
    fi
}


check_python_version () {
    local inpver="${1#AIO-}"
    _VALID_VERSION=$( $python -c "import packaging.version as v;print(v.Version('$inpver'),end='')" )
}

check_existing_AIO () {
    ##  Check existing AIO's version and decide future-one.

    if [ -z "${AIODIR:+x}" ];then
        die "no \$AIODIR variable is defined!" \
        "\n  command must launch from an AIO-1.7.3+ console!\nAborting."
    fi

    AIODIR="$( $cygpath "$AIODIR" )"
    local old_version_files="$( $find "$AIODIR" -maxdepth 1 -name "$VERSION_FILE_CHECK" -printf '%f ')"

    if [ -n "$old_version_files" ]; then
        if [ -n "$OLD_AIO_VERSION" ]; then
            warn "ignoring given old---aio-version: $OLD_AIO_VERSION"
        fi
        ## Leninent handling of multiple version-files.
        #
        local allvers=( $old_version_files ) # var-to-array from; https://stackoverflow.com/a/15108607/548792
        OLD_AIO_VERSION=${allvers[0]%.ver}
        OLD_AIO_VERSION=${OLD_AIO_VERSION#AIO-}
        if [ ${#allvers[@]} -ne 1 ]; then
            warn "existing AIO has ${#allvers[@]} version-files: ${allvers[@]}" \
            "\n  Arbitrarily assumed the first one as authoritative: $OLD_AIO_VERSION"
        fi

    else  # no version-file found
        local old_version
        local msg="cannot locate existing AIO's version-file: $AIODIR/$VERSION_FILE_CHECK"

        if [ -n "$OLD_AIO_VERSION" ]; then
            warn "$msg$blue\n  using given version: $OLD_AIO_VERSION"
            check_python_version "$OLD_AIO_VERSION" || die "invalid --old-aio-version $OLD_AIO_VERSION"

        else  # none given from cmdline, ask user.
            warn "$msg"

            while true; do
                read -p "${green}Which is your current AIO version? $reset" old_version
                [ -z "$old_version" ] && continue
                if check_python_version "$old_version"; then
                    OLD_AIO_VERSION="${_VALID_VERSION#AIO-}"
                    break
                fi
            done
        fi
    fi

    NEW_VERSION="${OLD_AIO_VERSION%?${NEW_VERSION}}.$NEW_VERSION"
}


clean_inflated () {
    if [ -z "$KEEP_INFLATED" ]; then
        debug "cleaning any inflated pack-files in temporary folders..."
        $infl_rm -rf "$INFLATE_DIR"
    fi

}


inflate_pack_files () {
    $infl_rm -rf "$INFLATE_DIR"  # clean any remnants
    info "inflating pack-files in '$INFLATE_DIR'..."

    ## Inflate lines after the 2nd(!) raw-bytes header.
    #
    local -i rawline=$($infl_awk \
                    '/UpgradePack_RAW_BYTES_BELOW/ { m++; if (m == 2) { print FNR + 2; exit }}' \
                    "$prog")
    mkdir -p "$INFLATE_DIR"
    trap 'clean_inflated' EXIT
    $infl_tail -n+$rawline "$prog" | $infl_tar -xj -C "$INFLATE_DIR"

    ## Check some expected dirs exist.
    #
    local inflation_err=''
    for exp_dir in AIO wheelhouse; do
        [ -d "$INFLATE_DIR/$exp_dir" ] || inflation_err="$inflation_err\n  - missing dir: $exp_dir/"
    done

    ## Count wheels.
    #
    local wheels="$( $find "$INFLATE_DIR/wheelhouse" -name '*.whl' )"
    wheels=( $wheels )
    local nwhl=${#wheels[@]}
    [ $nwhl -ne $WINPY_NPACKAGES ] && inflation_err="\n  - missmatch num-of-wheels: expected $WINPY_NPACKAGES, inflated $nwhl"

    if [ -n "$inflation_err" ]; then
        die "inflating upgrade-pack has failed due to: $inflation_err!\nAborting."
    fi
}


do_upgrade () {
    local old_version_file="$AIODIR/ΑΙΟ-$OLD_AIO_VERSION.ver"
    local new_version_file="$AIODIR/ΑΙΟ-$NEW_VERSION.ver"
    local -i nsteps=4
    local -i step=1

    logstep() {
        info "$step of $nsteps: $1"
        let step++
    }

    logstep "${DRY_RUN}engraving new version-file $new_version_file..."
    if [ -f "$old_version_file" ]; then
        $cp "$old_version_file" "$new_version_file"
    fi
    echo -e "\n$NEW_VERSION: $( $date )" | $tee -a "$AIODIR/AIO-$NEW_VERSION.ver" >&3

    logstep "${DRY_RUN}upgrading WinPython packages..."
    $pip install $PIP_INSTALL_OPTS "$INFLATE_DIR"/wheelhouse/*.whl

    logstep "${DRY_RUN}overlaying Apps files..."
    $rsync -r "$INFLATE_DIR/AIO/" "$AIODIR/"

    logstep "${DRY_RUN}patching console config (and TODO: fix MSYS2 unset vars)..."
    $sed -i "s/title=\"AIO-[^\"+]\"/title=\"AIO-$NEW_VERSION/" "$AIODIR/Apps/Console/console.xml"

    logstep "${DRY_RUN}deleting old version-file $old_version_file..."
    if [ -f "$old_version_file" ]; then
        $rm "$old_version_file"
    fi
}

####################################
## Main body
####################################
get_help
pargs_cmdline_args "$@"

notice "$HELP_OPENING\n  Use $prog --help for more options (e.g. --dry-run)"
inflate_pack_files
if [ -n "$INFLATE_ONLY" ]; then
    notice "inflated pack-files in '$INFLATE_DIR' and stopped."
    exit 0
fi
check_existing_AIO
prompt_for_abort
do_upgrade

notice "finished $DRY_RUN$SCRIPT_ACTION successfully."

exit 0
#######################################################################
#######################################################################
#######################################################################
#######################################################################
#######################################################################
#######################################################################
#######################################################################
#######################################################################
#######################################################################
##                  UpgradePack_RAW_BYTES_BELOW                      ##
#######################################################################
