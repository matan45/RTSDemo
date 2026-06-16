#!/usr/bin/env bash
# Copy edited GLSL from the source tree to the Editor (or Runtime) runtime shader path.
#
# The engine reads shaders from bin/<Target>/resources/shaders/, NOT the source
# resources/shaders/ tree. Editing source GLSL alone has no runtime effect until copied.
#
# Usage:
#   sync-shaders.sh [--runtime] [REL_PATH]
#     REL_PATH   single shader relative to resources/shaders/
#                (e.g. gpudriven/mesh_shader_gpudriven.glsl), or an absolute/source path.
#                If omitted, the whole resources/shaders/ tree is mirrored.
#     --runtime  sync into bin/Runtime/... instead of bin/Editor/...
#                (Runtime path is documented-but-unverified; default is Editor.)
set -euo pipefail

target="Editor"
shader=""
for arg in "$@"; do
  case "$arg" in
    --runtime) target="Runtime" ;;
    *)         shader="$arg" ;;
  esac
done

# Repo root = three levels up from .claude/skills/vulkan-graphics-dev/scripts/
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
src_root="$repo_root/resources/shaders"
dst_root="$repo_root/bin/$target/resources/shaders"

[ -d "$src_root" ] || { echo "Source shader tree not found: $src_root" >&2; exit 1; }

copy_one() {
  local rel="$1"
  local src="$src_root/$rel"
  [ -f "$src" ] || { echo "Shader not found: $src" >&2; exit 1; }
  local dst="$dst_root/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  echo "  $rel"
}

echo "Syncing shaders -> bin/$target/resources/shaders"

if [ -n "$shader" ]; then
  rel="$shader"
  # If an existing absolute/source path was given, derive the relative form.
  if [ -e "$shader" ]; then
    full="$(cd "$(dirname "$shader")" && pwd)/$(basename "$shader")"
    case "$full" in
      "$src_root"/*) rel="${full#"$src_root"/}" ;;
    esac
  fi
  copy_one "$rel"
else
  count=0
  while IFS= read -r -d '' f; do
    rel="${f#"$src_root"/}"
    copy_one "$rel"
    count=$((count + 1))
  done < <(find "$src_root" -type f -name '*.glsl' -print0)
  echo "Mirrored $count shader file(s)."
fi

echo "Done. Relaunch the Editor for changes to take effect."
