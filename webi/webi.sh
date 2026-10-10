#!/bin/sh

set -e
set -u
#set -x

WEBI_HOST="${WEBI_HOST:-https://webinstall.dev}"
WEBI_TIMESTAMP="${WEBI_TIMESTAMP:-$(date +%F_%H-%M-%S)}"

: "${WEBI_STALE_TIME:=600}"  # seconds after which cache should be refreshed in background
: "${WEBI_EXPIRY_TIME:=900}" # seconds after which cache must be refreshed before use

__webi_main() {

    if [ -n "${_WEBI_PARENT:-}" ]; then
        export _WEBI_CHILD=true
    else
        export _WEBI_CHILD=
    fi
    export _WEBI_PARENT=true

    WEBI_HOST="${WEBI_HOST%/}"

    export WEBI_HOST
    export WEBI_TIMESTAMP

    my_tmpdir="${TMPDIR:-/tmp}"
    my_tmpdir="${my_tmpdir%/}"

    ##
    ## Detect acceptable package formats
    ##

    my_ext=""
    set +e
    # NOTE: the order here is least favorable to most favorable
    if [ -n "$(command -v pkgutil)" ]; then
        my_ext="pkg,$my_ext"
    fi
    # disable this check for the sake of building the macOS installer on Linux
    #if [ -n "$(command -v diskutil)" ]; then
    # note: could also detect via hdiutil
    my_ext="dmg,$my_ext"
    #fi
    if [ -n "$(command -v git)" ]; then
        my_ext="git,$my_ext"
    fi
    if [ -n "$(command -v unzstd)" ] || [ -n "$(command -v zstd)" ]; then
        my_ext="zst,$my_ext"
    fi
    if [ -n "$(command -v unxz)" ]; then
        my_ext="xz,$my_ext"
    fi
    if [ -n "$(command -v unzip)" ]; then
        my_ext="zip,$my_ext"
    fi
    # for mac/linux 'exe' refers to the uncompressed binary without extension
    my_ext="exe,$my_ext"
    if [ -n "$(command -v tar)" ]; then
        my_ext="tar,$my_ext"
    fi
    my_ext="$(echo "$my_ext" | sed 's/,$//')" # nix trailing comma
    set -e

    webinstall() {

        b_package="${1:-}"
        if test -z "${b_package}"; then
            echo >&2 "Usage: webi <package>@<version> ..."
            echo >&2 "Example: webi node@lts rg"
            exit 1
        fi

        webi_create_tmpdir

        b_install_tmpdir="${_webi_tmp}/${b_package}-install"
        mkdir -p "${b_install_tmpdir}"

        my_installer_url="${WEBI_HOST}/api/installers/${b_package}.sh?formats=${my_ext}"
        if ! webi_curl "${my_installer_url}" "${b_install_tmpdir}/${b_package}-install.sh"; then
            fatal ERROR "Error fetching '${my_installer_url}'"
        fi
        (
            cd "${b_install_tmpdir}"
            sh "${b_package}-install.sh"
        )
    }

    show_path_updates() {

        if test -z "${_WEBI_CHILD}"; then
            webi_create_tmpdir
            if test -f "${_webi_tmp}/.PATH.env"; then
                my_paths=$(sort -u < "${_webi_tmp}/.PATH.env")
                if test -n "${my_paths}"; then
                    printf 'PATH.env updated with:\n'
                    printf "%s\n" "${my_paths}"
                    printf '\n'
                    printf "\e[1m\e[35mTO FINISH\e[0m: copy, paste & run the following command:\n"
                    printf "\n"
                    printf "        \e[1m\e[32msource ~/.config/envman/PATH.env\e[0m\n"
                    printf "        (newly opened terminal windows will update automatically)\n"
                fi
                rm -f "${_webi_tmp}/.PATH.env"
            fi
        fi

    }

    fn_checksum() {
        a_filepath="${1}"

        if command -v sha1sum > /dev/null; then
            sha1sum "${a_filepath}" | cut -d' ' -f1 | cut -c 1-8
            return 0
        fi

        if command -v shasum > /dev/null; then
            shasum "${a_filepath}" | cut -d' ' -f1 | cut -c 1-8
            return 0
        fi

        if command -v sha1 > /dev/null; then
            sha1 "${a_filepath}" | cut -d'=' -f2 | cut -c 2-9
            return 0
        fi

        log WARNING "no sha1 sum program"
        date '+%F %H:%M'
    }

    version() {
        my_checksum="$(
            fn_checksum "${0}"
        )"
        my_version=v1.2.8
        printf "\e[35mwebi\e[32m %s\e[0m Copyright 2020+ AJ ONeal\n" "${my_version} (${my_checksum})"
        printf "    \e[36mhttps://webinstall.dev/webi\e[0m\n"
    }

    # show help if no params given or help flags are used
    usage() {
        echo ""
        version
        echo ""

        printf "\e[1mSUMMARY\e[0m\n"
        echo "    Webi is the best way to install the modern developer tools you love."
        echo "    It's fast, easy-to-remember, and conflict free."
        echo ""
        printf "\e[1mUSAGE\e[0m\n"
        echo "    webi <thing1>[@version] [thing2] ..."
        echo ""
        printf "\e[1mUNINSTALL\e[0m\n"
        echo "    Almost everything that is installed with webi is scoped to"
        echo "    ~/.local/opt/<thing1>, so you can remove it like so:"
        echo ""
        echo "    rm -rf ~/.local/opt/<thing1>"
        echo "    rm -f ~/.local/bin/<thing1>"
        echo ""
        echo "    Some packages have special uninstall instructions, check"
        echo "    https://webinstall.dev/<thing1> to be sure."
        echo ""
        printf "\e[1mOPTIONS\e[0m\n"
        echo "    Generic Program Information"
        echo "        --help Output a usage message and exit."
        echo ""
        echo "        -V, --version"
        echo "               Output the version number of webi and exit."
        echo ""
        echo "    Helper Utilities"
        echo "        --init Register command line completions with shell"
        echo ""
        echo "        --list Show everything webi has to offer."
        echo ""
        echo "        --info <package>"
        echo "               Show various links and example release."
        echo ""
        printf "\e[1mFAQ\e[0m\n"
        printf "    See \e[34mhttps://webinstall.dev/faq\e[0m\n"
        echo ""
        printf "\e[1mALWAYS REMEMBER\e[0m\n"
        echo "    Friends don't let friends use brew for simple, modern tools that don't need it."
        echo "    (and certainly not apt either **shudder**)"
        echo ""
    }

    if [ $# -eq 0 ] || echo "$1" | grep -q -E '^(-V|--version|version)$'; then
        version
        exit 0
    fi

    if echo "$1" | grep -q -E '^(-h|--help|help)$'; then
        usage "$@"
        exit 0
    fi

    if echo "$1" | grep -q -E '^(--list|list)$'; then
        webi_list
        exit 0
    fi

    if echo "${1}" | grep -q -E '^(--info|info)$'; then
        webi_info "$@"
        exit 0
    fi

    if echo "$1" | grep -q -E '^(--init|init)$'; then
        webi_shell_init "$@"
        exit 0
    fi

    for pkgname in "$@"; do
        webinstall "${pkgname}"
        export WEBI_WELCOME='shown'
    done

    show_path_updates

}

webi_create_tmpdir() {
    # If the directory already exists and is writable, use it
    [ -d "${_webi_tmp:-}" ] && [ -w "${_webi_tmp}" ] && return 0

    # Create a job-specific temp directory
    _webi_tmp="$(mktemp -d "${my_tmpdir}/webi-${WEBI_TIMESTAMP}.XXXXXXXX")" || return 1
    export _webi_tmp

    # and traps to clean it up on exit.
    if [ -z "${_webi_keep_tmp:-}" ]; then
        trap 'rm -rf "$_webi_tmp"' EXIT
        trap 'exit 1' HUP INT TERM
    fi
}

webi_load_sysinfo() {
    # ex: Darwin or Linux
    my_os="$(uname -s)"
    # ex: 22.6.0
    my_rev="$(uname -r)"
    # ex: arm64
    my_arch="$(uname -m)"

    if [ -z "${WEBI_UA:-}" ]; then
        my_uname_o="$(uname -o 2> /dev/null || echo '')"
        my_libc=''
        if ldd /bin/ls 2> /dev/null | grep -q 'musl' 2> /dev/null; then
            my_libc='musl'
        elif echo "${my_uname_o}" | grep -q 'GNU' || uname -s | grep -q 'Linux'; then
            my_libc='gnu'
        else
            my_libc='libc'
        fi

        export WEBI_UA="${my_os}/${my_rev} ${my_arch}/unknown ${my_libc}"
    fi
}

fatal () {
    log "$@"
    exit 1
}

color () {
    # Usage:
    #   colorcode '1;31' 'this is bold red'
    #   colorcode '35'   'this is magenta on stderr' 2
    color_color="${1}"
    color_text="${2}"
    color_fd=${3:-1}

    if  [ -z "${color_color:-}" ] ||
        [ -n "${NO_COLOR:-}${NOCOLOR:-}${NO_COLOUR:-}${NOCOLOUR:-}" ] ||
        [ "${TERM:-dumb}" = "dumb" ] ||
        [ ! -t "${color_fd}" ]; then
        printf "%s" "${color_text}" >&"${color_fd}"
    else
        printf "\033[%sm%s\033[0m" "${color_color}" "${color_text}" >&"${color_fd}"
    fi
}

log () {
    my_level="${1}" my_message="${2}"
    my_eol="\012"
    [ -z "${my_message}" ] && fatal CRITICAL "no message"

    my_color=
    case "${my_level}" in
        CRITICAL) my_color='35' ;;
        ERROR)    my_color='31' ;;
        WARNING)  my_color='33' ;;
        NOTICE)   my_color='39' ;;
        INFO)     my_color='36' ;;
        DEBUG)    my_color='2'  ;;
        '') [ -z "${SILENT:-}" ] && printf "%s%s" "${my_message}" "${my_eol}"
            return 0
            ;;
        *)  fatal CRITICAL "bad log level: ${my_level}"
            ;;
    esac

    my_prefix="${my_level:+[$my_level]}"
    case "${my_level}" in
        CRITICAL) ;;
        INFO)         [ -z "${VERBOSE:-}${DEBUG:-}" ] && return 0 ;;
        DEBUG)        [ -z "${DEBUG:-}" ] && return 0 ;;
        *)            [ -n "${SILENT:-}" ] && return 0 ;;
    esac

    my_prefix="$(printf "%10s" "${my_prefix:+$my_prefix}")"
    if [ -z "${COLORPREFIX:-${COLOURPREFIX:-}}" ]; then
        color "1;${my_color}" "${my_prefix}" 2
        color "${my_color}"   " ${my_message}" 2
    else
        color "${my_color}" "${my_prefix}" 2
        color "" " ${my_message}${my_eol}" 2
    fi
}

# Download $1 to file $2 ('-' for stdout) with curl or wget, returning its rc.
# Uses WEBI_CURL (preferred) or WEBI_WGET if set; otherwise detects curl, then
# wget. Not a subshell, so detection persists (unless called within $(...)).
webi_curl() {
    curl_url="${1:-}"
    [ -z "${curl_url}" ] && fatal ERROR "no URL specified"

    curl_file="${2:-}"
    [ -z "${curl_file}" ] && fatal ERROR "no file specified; use '-' for stdout"

    # get WEBI_UA
    webi_load_sysinfo

    # Detect curl, or failing that, wget
    if [ -z "${WEBI_CURL:-}" ] && [ -z "${WEBI_WGET:-}" ]; then
        if b_cmd="$(command -v curl)" && "$b_cmd" --version > /dev/null 2>&1; then
            WEBI_CURL="$b_cmd"
        elif b_cmd="$(command -v wget)"; then
            # no --version check: busybox wget doesn't support it
            WEBI_WGET="$b_cmd"
        fi
    fi

    if [ -n "${WEBI_CURL:-}" ]; then
        "${WEBI_CURL}" -fsSL "$curl_url" -H "User-Agent: curl ${WEBI_UA}" -o "$curl_file"
        return $?
    elif [ -n "${WEBI_WGET:-}" ]; then
        "${WEBI_WGET}" -q "$curl_url" --user-agent="wget ${WEBI_UA}" -O "$curl_file"
        return $?
    fi

    fatal ERROR "neither 'curl' nor 'wget' found or working"
}

webi_shell_init() { (
    a_shell="${2:-}"

    fn_shell_integrate_bash ""
    fn_shell_integrate_zsh ""
    fn_shell_integrate_fish ""

    # update completions now
    webi_list > /dev/null

    if [ $# -eq 1 ]; then
        exit 0
    fi

    case "${a_shell}" in
        bash)
            fn_shell_integrate_bash "force"
            fn_shell_init_bash
            ;;
        zsh)
            fn_shell_integrate_zsh "force"
            fn_shell_init_zsh
            ;;
        fish)
            fn_shell_integrate_fish "force"
            fn_shell_init_fish
            ;;
        *)
            fatal ERROR "Unsupported shell: $2"
            ;;
    esac
) }

fn_shell_integrate_bash() { (
    a_force="${1}"
    if test -z "${a_force}"; then
        if ! command -v bash > /dev/null; then
            return 0
        fi

        if ! test -e ~/.bashrc && ! test -e ~/.bash_history; then
            return 0
        fi
    fi

    touch -a ~/.bashrc
    if grep -q 'webi --init' ~/.bashrc; then
        return 0
    fi

    # shellcheck disable=SC2016
    {
        echo ''
        echo '# Generated by Webi. Do not edit.'
        echo 'eval "$(webi --init bash)"'
    } >> ~/.bashrc
); }

# shellcheck disable=SC2016
fn_shell_init_bash() { (
    echo '_webi() {'
    echo '    COMPREPLY=()'
    echo '    local cur="${COMP_WORDS[COMP_CWORD]}"'
    echo '    if [ "$COMP_CWORD" -eq 1 ]; then'
    echo '        local completions=$(webi --list | cut -d" " -f1)'
    echo '        COMPREPLY=( $(compgen -W "$completions" -- "$cur") )'
    echo '    fi'
    echo '}'
    echo ''
    echo 'complete -F _webi webi'
); }

fn_shell_integrate_zsh() { (
    a_force="${1}"
    if test -z "${a_force}"; then
        if ! command -v zsh > /dev/null; then
            return 0
        fi

        if ! test -e ~/.zshrc &&
            ! test -e ~/.zsh_sessions &&
            ! test -e ~/.zsh_history; then
            return 0
        fi
    fi

    touch -a ~/.zshrc
    if grep -q 'webi --init' ~/.zshrc; then
        return 0
    fi

    # shellcheck disable=SC2016
    {
        echo ''
        echo '# Generated by Webi. Do not edit.'
        echo 'eval "$(webi --init zsh)"'
    } >> ~/.zshrc
); }

# shellcheck disable=SC2016
fn_shell_init_zsh() { (
    echo '_webi() {'
    echo '    local -a list completions'
    echo '    list=$(webi --list | cut -d" " -f1)'
    echo '    completions=(${(f)list})'
    echo '    _describe -t commands "command" completions && ret=0'
    echo '}'
    echo ''
    echo '[[ $functions[compdef] ]] || { autoload -Uz compinit && compinit }'
    echo 'compdef _webi webi'
); }

fn_shell_integrate_fish() { (
    a_force="${1}"
    if test -z "${a_force}"; then
        if ! command -v fish > /dev/null; then
            return 0
        fi
    fi

    mkdir -p ~/.config/fish
    touch -a ~/.config/fish/config.fish
    if grep -q 'webi --init' ~/.config/fish/config.fish; then
        return 0
    fi

    # shellcheck disable=SC2016
    {
        echo ''
        echo '# Generated by Webi. Do not edit.'
        echo 'webi --init fish | source'
    } >> ~/.config/fish/config.fish
); }

# shellcheck disable=SC2016
fn_shell_init_fish() { (
    echo 'function __fish_webi_needs_command'
    echo '    set cmd (commandline -opc)'
    echo '    if [ (count $cmd) -eq 1 -a $cmd[1] = "webi" ]'
    echo '        return 0'
    echo '    end'
    echo '    return 1'
    echo 'end'
    echo ''
    echo 'set completions (webi --list | cut -d" " -f1)'
    echo 'complete -f -c webi -n __fish_webi_needs_command -a "$completions"'
); }

webi_list() { (
    # To avoid ownership collision with other users when using sudo,
    # save the list per-user
    my_uid="$(id -u)"
    my_tmpbase="webi.uid-${my_uid}.list"

    # Get all cached list files with my uid that I own, most recent first (-t)
    my_lists="$(
        find "${my_tmpdir}/." \
            ! -name . -prune \
            -type f \
            -user "${my_uid}" \
            -name "${my_tmpbase}.*" \
            -exec ls -t {} + 2> /dev/null
    )"

    my_list=
    my_list_age=0
    # If we have any existing lists...
    if [ -n "${my_lists}" ]; then
        # Take the most recent (first) valid file and delete any others
        while IFS= read -r my_file; do
            if [ -z "${my_list}" ] && [ -s "${my_file}" ]; then
                my_list="${my_file}"
            else
                rm -f "${my_file}" || true
            fi
        done << EOF
${my_lists}
EOF

        # Get age of file if it exists and is not empty
        my_list_age="$((WEBI_EXPIRY_TIME + 1))"
        if [ -n "${my_list}" ]; then
            my_now="$(date -u '+%s')"
            my_list_date="$(date -u -r "${my_list}" '+%s' 2> /dev/null || echo '0')"
            if [ "${my_list_date}" -gt 0 ]; then
                my_list_age="$((my_now - my_list_date))"
            else
                # 'date -r FILE' probably fails on OpenBSD, NetBSD, Solaris, AIX, etc.
                # but should work on GNU, macOS, FreeBSD.
                log_error "[warn] can't get mtime of '${my_list}'"
                my_list_date=0
            fi
        fi
    fi

    if [ -z "${my_list}" ] || [ "${my_list_age}" -gt "${WEBI_EXPIRY_TIME}" ]; then
        # Download fresh list; can lose a race condition here, but no matter
        # as the file will be the same for all competitors
        my_new_list="$(fn_list_uncached "${my_tmpdir}" "${my_tmpbase}")" &&
            my_list="${my_new_list}"

    elif [ "${my_list_age}" -gt "${WEBI_STALE_TIME}" ]; then
        # freshen the file to avoid race conditions
        touch "${my_list}" 2> /dev/null || true
        # refresh in background
        fn_list_uncached "${my_tmpdir}" "${my_tmpbase}" > /dev/null &
    fi

    # Output the list
    if [ -s "${my_list}" ]; then
        cat "${my_list}"
        return 0
    fi
); }

fn_list_options() { (
    echo "help"
    echo "--help"
    echo "version"
    echo "-V"
    echo "--version"
    echo "--init" # <shell>
    echo "--list"
    echo "--info" # <package>
); }

fn_list_uncached() { (
    my_tmpdir="$1"
    my_tmpbase="$2"

    # Download sitemap, and fail this function on error.
    my_sitemap="$(webi_curl "${WEBI_HOST%/}/sitemap.xml" -)" || return 1

    # Construct intermediate file in per-job temp directory to avoid race
    # conditions with other processes.
    webi_create_tmpdir
    my_intermediate="$(mktemp "${_webi_tmp}/download-${my_tmpbase}.XXXXXXXX")" || return 1
    fn_list_options > "${my_intermediate}"

    # Strip just the path from <loc>$my_host/path</loc>
    printf '%s\n' "${my_sitemap}" |
        awk -F'[<>]' \
            -v h="${WEBI_HOST%/}/" \
            'BEGIN {l=length(h)+1} index($3,h)==1 {print substr($3,l)}' \
            >> "${my_intermediate}"

    # Save to the cache file that will persist after this job (and cleaned up
    # by either the OS or a later run of webi, if expired)
    my_list_file="$(mktemp "${my_tmpdir}/${my_tmpbase}.XXXXXXXX")" || return 1
    cat "${my_intermediate}" > "${my_list_file}"
    rm -f "${my_intermediate}"

    # Return the file path
    echo "${my_list_file}"
); }

webi_info() { (
    if [ $# -lt 2 ]; then
        fatal ERROR "Usage: webi --info <package>"
    fi

    webi_load_sysinfo

    log WARNING "the output of --info is completely half-baked and will change"
    my_pkg="${2}"
    # TODO need a way to check that it exists at all (readme, win, lin)
    echo ""
    echo "    Cheat Sheet: ${WEBI_HOST}/${my_pkg}"
    echo "          POSIX: curl -sS ${WEBI_HOST}/${my_pkg} | sh"
    echo "        Windows: curl.exe -A MS ${WEBI_HOST}/${my_pkg} | powershell"
    echo "Releases (JSON): ${WEBI_HOST}/api/releases/${my_pkg}.json"
    echo " Releases (tsv): ${WEBI_HOST}/api/releases/${my_pkg}.tab"
    echo " (query params):     ?channel=stable&limit=10"
    echo "                     &os=${my_os}&arch=${my_arch}"
    echo " Install Script: ${WEBI_HOST}/api/installers/${my_pkg}.sh?formats=tar,zip,xz,git,dmg,pkg"
    echo "  Static Assets: ${WEBI_HOST}/packages/${my_pkg}/README.md"
    echo ""

    # TODO os=linux,macos,windows (limit to tagged releases)
    my_releases="$(
        webi_curl "${WEBI_HOST}/api/releases/${my_pkg}.json?channel=stable&limit=1&pretty=true" -
    )"

    if printf '%s\n' "${my_releases}" | grep -q "error"; then
        my_releases_beta="$(
            webi_curl "${WEBI_HOST}/api/releases/${my_pkg}.json?&limit=1&pretty=true" -
        )"
        if printf '%s\n' "${my_releases_beta}" | grep -q "error"; then
            # XXX: This occurs even if a non-existent package is requested
            log WARNING "'${my_pkg}' is a special case that does not have releases"
        else
            log WARNING "no stable releases for '${my_pkg}'!"
        fi
        exit 0
    fi

    echo "Stable '${my_pkg}' releases:"
    if command -v jq > /dev/null; then
        printf '%s\n' "${my_releases}" |
            jq
    else
        printf '%s\n' "${my_releases}"
    fi
); }

__webi_main "$@"
