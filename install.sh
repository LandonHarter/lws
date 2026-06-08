#!/usr/bin/env sh
set -eu

REPO="${LWS_REPO:-LandonHarter/lws}"
LWS_HOME="${LWS_HOME:-$HOME/.lws}"
VERSION="${LWS_VERSION:-latest}"

die() { printf "error: %s\n" "$*" >&2; exit 1; }
info() { printf "%s\n" "$*"; }

detect_target() {
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "$uname_s" in
    Darwin)
      case "$uname_m" in
        arm64|aarch64) echo "aarch64-macos" ;;
        x86_64)        echo "x86_64-macos" ;;
        *) die "unsupported macOS arch: $uname_m" ;;
      esac ;;
    Linux)
      case "$uname_m" in
        aarch64|arm64) echo "aarch64-linux-gnu" ;;
        x86_64)        echo "x86_64-linux-gnu" ;;
        *) die "unsupported Linux arch: $uname_m" ;;
      esac ;;
    *) die "unsupported OS: $uname_s (Windows users: download the zip from the releases page)" ;;
  esac
}

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    api_url="https://api.github.com/repos/${REPO}/releases/latest"
    VERSION="$(curl -fsSL "$api_url" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || die "could not resolve latest version from $api_url"
  fi
  echo "$VERSION"
}

setup_path() {
  bin_dir="${LWS_HOME}/bin"
  case ":$PATH:" in
    *:"${bin_dir}":*) return ;;
  esac

  line="export PATH=\"${bin_dir}:\$PATH\""
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] || continue
    if ! grep -Fq "${bin_dir}" "$rc"; then
      printf "\n# Added by LWS install script\n%s\n" "$line" >> "$rc"
      info "added PATH entry to ${rc}"
    fi
  done

  fish_config="$HOME/.config/fish/config.fish"
  if [ -f "$fish_config" ] && ! grep -Fq "${bin_dir}" "$fish_config"; then
    printf "\n# Added by LWS install script\nfish_add_path %s\n" "$bin_dir" >> "$fish_config"
    info "added PATH entry to ${fish_config}"
  fi
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar  >/dev/null 2>&1 || die "tar is required"

  target="$(detect_target)"
  version="$(resolve_version)"

  tarball="lws-${version}-${target}.tar.gz"
  url="https://github.com/${REPO}/releases/download/v${version}/${tarball}"

  info "downloading ${tarball}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "${tmp}/${tarball}" "$url"

  info "extracting to ${LWS_HOME}"
  mkdir -p "${LWS_HOME}"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}"
  staged="${tmp}/lws-${version}-${target}"
  rm -rf "${LWS_HOME:?}/bin" "${LWS_HOME:?}/share"
  mv "${staged}/bin" "${LWS_HOME}/bin"
  mv "${staged}/share" "${LWS_HOME}/share"

  if [ "$(uname -s)" = "Darwin" ]; then
    xattr -dr com.apple.quarantine "${LWS_HOME}" 2>/dev/null || true
  fi

  setup_path

  info ""
  info "installed lws ${version} to ${LWS_HOME}"
  info "run: lws version"
  info ""
  info "if 'lws' isn't found, restart your shell or run:  source ~/.zshrc  (or your shell's rc file)"
}

main "$@"
