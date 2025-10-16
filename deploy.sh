#!/bin/bash
set -e

# Constants
ORIGINAL_REPO="fiyge/bundle-development"
URL_PROTOCOL="https"  # Change to "ssh" if preferred for submodule URLs
DEFAULT_BRANCH="main"  # Assuming the default branch is 'main'; adjust if necessary

# Function to handle GitHub authentication
function authenticate() {
  echo "Do you want to authenticate with a different GitHub account? This will log out the current session and open a browser for SSO login. (y/n)"
  read -r response
  if [[ $response =~ ^[yY]$ ]]; then
    gh auth logout
    gh auth login --web || {
      echo "Authentication failed. Please ensure 'gh' is installed and try again."
      exit 1
    }
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

  echo "Forking the main repository ($repo)..."
  gh repo fork "$repo" --clone=false || {
    echo "Error: Forking failed. A conflicting operation may be in progress. Waiting 10 seconds and retrying..."
    sleep 10
    gh repo fork "$repo" --clone=false || {
      echo "Error: Forking failed again. Check for existing forks or GitHub API issues."
      exit 1
    }
  }

  temporary_forked="${username}/${vertical_name}"
  echo "Renaming the forked repository to: $forked_name"
  gh repo rename "$forked_name" --repo "$temporary_forked" --yes || {
    echo "Warning: Rename failed (possibly name conflict). Continuing with original forked name."
    forked_name="$vertical_name"
  }
  forked_main="${username}/${forked_name}"

  # Check for existing directory and append suffix if needed
  clone_dir="$forked_name"
  counter=1
  while [ -d "$clone_dir" ]; do
    clone_dir="${forked_name}-${counter}"
    ((counter++))
  done

  echo "Cloning the forked repository to directory: $clone_dir..."
  git clone "https://github.com/${forked_main}.git" "$clone_dir"
  cd "$clone_dir"
  echo "${forked_main}"
}

# Function to process and relink submodules
function process_submodules() {
  local url_protocol=$1
  local username=$2

  if [ ! -f .gitmodules ]; then
    echo "No .gitmodules file found. No submodules to process."
    return
  fi

  current_branch=$(git branch --show-current)
  echo "Scanning .gitmodules for submodules to fork and relink..."

  # Use process substitution (< <(...)) to avoid creating a subshell that would prevent variable updates.
  while read -r key path_val; do
    # $key is 'submodule.NAME.path'
    # $path_val is the actual path, e.g., 'client/module/sub1'

    # Filter for submodules in the specified directory
    if [[ "$path_val" != client/module/* ]]; then
      continue
    fi

    echo "-----------------------------------------------------"
    echo "Processing submodule at path: $path_val"

    # Extract the submodule's logical name from the key for robust URL lookup
    name=$(echo "$key" | sed -E 's/^submodule\.(.*)\.path$/\1/')
    
    # Get the URL using the correct logical name
    url=$(git config --file .gitmodules --get "submodule.${name}.url")
    echo "Original URL: $url"

    # Parse the original submodule repo (owner/repo) from URL
    if [[ $url == git@* ]]; then
      tmp="${url#git@github.com:}"
      sub_original="${tmp%.git}"
    elif [[ $url == https://* ]]; then
      tmp="${url#https://github.com/}"
      sub_original="${tmp%.git}"
    else
      echo "Warning: Unsupported submodule URL format: $url. Skipping."
      continue
    fi
    sub_repo_name="${sub_original#*/}"
    echo "Original repository: $sub_original"
    
    # Fork the submodule repo
    echo "Attempting to fork $sub_original..."
    if ! gh repo fork "$sub_original" --clone=false; then
      echo "Warning: Failed to fork submodule $sub_original. It might already be forked or you lack permissions. Skipping."
      continue
    fi
    echo "Successfully forked $sub_original to your account ($username)."

    forked_sub="${username}/${sub_repo_name}"
    
    # Construct the new URL based on the specified protocol
    if [ "$url_protocol" = "ssh" ]; then
      new_url="git@github.com:${forked_sub}.git"
    else
      new_url="https://github.com/${forked_sub}.git"
    fi
    echo "New URL will be: $new_url"

    # Update the submodule URL directly in .gitmodules
    git config -f .gitmodules "submodule.${name}.url" "$new_url"
    echo "Updated .gitmodules for '$name'."

  done < <(git config --file .gitmodules --get-regexp '^submodule\..*\.path$')

  # After the loop, check if .gitmodules was modified and commit/push the changes.
  if ! git diff --quiet --exit-code .gitmodules; then
    echo "-----------------------------------------------------"
    echo "Committing URL changes in .gitmodules..."
    git add .gitmodules
    git commit -m "chore(submodules): Relink submodules in client/module to forked versions"
    
    echo "Pushing updates to the forked repository on branch '$current_branch'..."
    git push origin "$current_branch"
  else
    echo "-----------------------------------------------------"
    echo "No submodules were relinked. No changes to commit."
  fi
}


# Function to clean up local submodules for a fresh state
function cleanup_submodules() {
  echo "-----------------------------------------------------"
  echo "The remote repository has been updated with the new submodule links."
  echo "Cleaning up local submodule workspace to provide a fresh clone state..."
  
  # This command deinitializes all submodules, removing their entries from .git/config
  # and clearing the local submodule directories.
  git submodule deinit --all --force > /dev/null
  echo "Local submodule configurations have been removed."
}

# Main logic
if [ -z "$ORIGINAL_REPO" ]; then
  echo "Error: ORIGINAL_REPO is not set."
  exit 1
fi

echo "Choose deployment path: (1) Branching or (2) Forking"
read -r choice

authenticate
your_username=$(gh api user --jq '.login')

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
    process_submodules "$URL_PROTOCOL" "$your_username"
    cleanup_submodules
    echo "====================================================="
    echo "✅ Process complete!"
    echo "Forked repository URL: https://github.com/${forked_main}"
    echo "To work with the submodules locally, navigate to the repo directory and run:"
    echo "git submodule update --init --recursive"
    echo "====================================================="
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac