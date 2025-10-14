#!/bin/bash

set -e

# Constants
ORIGINAL_REPO="fiyge/bundle-development"
URL_PROTOCOL="https"  # Change to "ssh" if preferred for submodule URLs
DEFAULT_BRANCH="main"  # Assuming the default branch is 'main'; adjust if necessary

# Design Pattern: Modular functions for better structure and reusability

# Function to handle GitHub authentication
function authenticate() {
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
  echo "Authenticated as: $your_username"
}

# Function to check write access to the repository
function check_write_access() {
  local repo=$1
  local username=$2

  permission=$(gh api "repos/${repo}/collaborators/${username}/permission" --jq '.permission' 2>/dev/null || echo "none")
  if [[ "$permission" == "write" || "$permission" == "admin" ]]; then
    return 0  # Has access
  else
    return 1  # No access
  fi
}

# Function to create a new branch
function create_branch() {
  local repo=$1
  local username=$2
  local branch_name="instance/${username}"

  # Get the SHA of the default branch
  default_sha=$(gh api "repos/${repo}/branches/${DEFAULT_BRANCH}" --jq '.commit.sha')

  # Create the new branch
  gh api "repos/${repo}/git/refs" -X POST -f "ref=refs/heads/${branch_name}" -f "sha=${default_sha}" >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo "Branch '${branch_name}' created successfully in ${repo}."
  else
    echo "Error: Failed to create branch '${branch_name}'. It may already exist."
  fi
}

# Function to fork the main repository
function fork_main_repo() {
  local repo=$1
  local username=$2

  vertical_name="${repo#*/}"
  random_suffix=$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)
  forked_name="${vertical_name}-fork-${random_suffix}"

  echo "Forking the main repository..."
  gh repo fork "$repo" --clone=false

  temporary_forked="${username}/${vertical_name}"

  echo "Renaming the forked repository to: $forked_name"
  gh repo rename "$forked_name" --repo "$temporary_forked" --yes || {
    echo "Warning: Rename failed (possibly name conflict). Continuing with original forked name."
    forked_name="$vertical_name"
  }

  forked_main="${username}/${forked_name}"

  echo "Cloning the forked repository..."
  git clone "https://github.com/${forked_main}.git" "$forked_name"
  cd "$forked_name"

  echo "${forked_main}"
}

# Function to process and relink submodules
function process_submodules() {
  local url_protocol=$1

  current_branch=$(git branch --show-current)
  submodules=$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' || true)
  changes_made=false

  if [ -z "$submodules" ]; then
    echo "No submodules found. Nothing to fork or relink."
    return
  fi

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

    # Check if the submodule repo is accessible
    if gh repo view "$sub_original" >/dev/null 2>&1; then
      echo "Forking accessible submodule $sub_original..."
      gh repo fork "$sub_original" --clone=false

      forked_sub="${your_username}/${sub_repo_name}"

      if [ "$url_protocol" = "ssh" ]; then
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
    echo "Pushing updates to the forked repository..."
    git push origin "$current_branch"
  else
    echo "No submodules were relinked."
  fi
}

# Function to clean up local submodules
function cleanup_submodules() {
  submodules=$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' || true)
  echo "Cleaning up local submodule copies to save space..."
  for path in $submodules; do
    if [ -d "$path" ]; then
      git submodule deinit -f -- "$path" || true
      rm -rf "$path"
      rm -rf ".git/modules/$path"
    fi
  done
}

# Main logic
if [ -z "$ORIGINAL_REPO" ]; then
  echo "Error: ORIGINAL_REPO is not set."
  exit 1
fi

echo "Choose deployment path: (1) Branching or (2) Forking"
read -r choice

authenticate
your_username=$(gh api user --jq '.login')  # Already set in authenticate, but ensure

case "$choice" in
  1)
    echo "Selected Branching path."
    if check_write_access "$ORIGINAL_REPO" "$your_username"; then
      create_branch "$ORIGINAL_REPO" "$your_username"
    else
      echo "You don't have write access to the repository. Please select the Forking path."
    fi
    ;;
  2)
    echo "Selected Forking path."
    forked_main=$(fork_main_repo "$ORIGINAL_REPO" "$your_username")
    process_submodules "$URL_PROTOCOL"
    cleanup_submodules
    echo "Process complete. Forked repository: https://github.com/${forked_main}"
    echo "Remember to run 'git submodule update --init --recursive' in the cloned repo if needed."
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac