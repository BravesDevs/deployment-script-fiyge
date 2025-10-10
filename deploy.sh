#!/bin/bash

set -e

# Global variables for easy control
ORIGINAL_REPO="BravesDevs/submodules"
URL_PROTOCOL="https"  # Change to "ssh" if preferred for submodule URLs

if [ -z "$ORIGINAL_REPO" ]; then
  echo "Error: ORIGINAL_REPO is not set."
  exit 1
fi

echo "To fork the repository, you may need a different account if you own the parent or already have a fork."
echo "Do you want to authenticate with a different GitHub account? This will log out the current session and open a browser for SSO login. (y/n)"
read -r response
if [[ $response =~ ^[yY]$ ]]; then
  gh auth logout
  gh auth login --web
fi

your_username=$(gh api user --jq '.login')
if [ -z "$your_username" ]; then
  echo "Error: Could not determine GitHub username. Ensure gh is authenticated."
  exit 1
fi

vertical_name="${ORIGINAL_REPO#*/}"
random_suffix=$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)
forked_name="${vertical_name}-fork-${random_suffix}"

echo "Forking the main vertical repository..."
gh repo fork "$ORIGINAL_REPO" --clone=false

temporary_forked="${your_username}/${vertical_name}"

echo "Renaming the forked repository to a random name: $forked_name"
gh repo rename "$forked_name" --repo "$temporary_forked" --yes || {
  echo "Warning: Rename failed (possibly name conflict). Continuing with original forked name."
  forked_name="$vertical_name"
}

forked_main="${your_username}/${forked_name}"

echo "Cloning the forked vertical repository..."
git clone "https://github.com/${forked_main}.git" "$forked_name"
cd "$forked_name"

current_branch=$(git branch --show-current)

echo "Identifying submodules..."
submodules=$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' || true)

changes_made=false

if [ -z "$submodules" ]; then
  echo "No submodules found. Nothing to fork or relink."
else
  for path in $submodules; do
    echo "Processing submodule at path: $path"

    url=$(git config --file .gitmodules --get "submodule.${path}.url")

    # Parse the original submodule repo (owner/repo) from URL
    if [[ $url == git@* ]]; then
      tmp="${url#git@github.com:}"
      sub_original="${tmp%.git}"
    elif [[ $url == https://* ]]; then
      tmp="${url#https://github.com/}"
      sub_original="${tmp%.git}"
    else
      echo "Unsupported submodule URL format: $url"
      continue
    fi

    sub_repo_name="${sub_original#*/}"

    # Check if the submodule repo is accessible (public or user has access)
    if gh repo view "$sub_original" >/dev/null 2>&1; then
      echo "Forking accessible submodule $sub_original..."
      gh repo fork "$sub_original" --clone=false

      forked_sub="${your_username}/${sub_repo_name}"

      if [ "$URL_PROTOCOL" = "ssh" ]; then
        new_url="git@github.com:${forked_sub}.git"
      else
        new_url="https://github.com/${forked_sub}.git"
      fi

      echo "Delinking the original submodule..."
      git submodule deinit -f -- "$path"
      rm -rf ".git/modules/$path"
      git rm -f "$path"

      echo "Linking the forked submodule..."
      git submodule add "$new_url" "$path"

      changes_made=true
    else
      echo "Submodule $sub_original is inaccessible (private or no access). Skipping forking and keeping original link."
    fi
  done

  if $changes_made; then
    echo "Committing changes to relink submodules..."
    git commit -m "Relinked accessible submodules to forked versions" || echo "No changes to commit."
  else
    echo "No submodules were relinked."
  fi
fi

echo "Pushing updates to the forked vertical repository..."
git push origin "$current_branch"

echo "Process complete. Forked vertical repository: https://github.com/${forked_main}"
echo "Remember to run 'git submodule update --init --recursive' in the cloned repo if needed."