#!/usr/bin/env bash
set -e

# --- Error Handling ---
ctrl_c() {
  echo "** End."
  sleep 1
}
trap ctrl_c INT SIGINT SIGTERM ERR EXIT

# --- Colors ---
ALL_OFF="\e[1;0m"
BBOLD="\e[1;1m"
BLUE="${BBOLD}\e[1;34m"
GREEN="${BBOLD}\e[1;32m"
RED="${BBOLD}\e[1;31m"
YELLOW="${BBOLD}\e[1;33m"
export GUM_INPUT_WIDTH=0

DISTRO=$(lsb_release -si)

# --- Display Function ---
say() {
  echo -e "${2}${1}${ALL_OFF}"
  sleep 1
}

# --- Sudoers Setup (Idempotent) ---
setup_sudoers() {
  echo "Setting up sudoers for ${USER}..."

  # Check if sudoers entry already exists
  if grep -q "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" /etc/sudoers.d/99-${USER}; then
    say "Sudoers entry already exists.\n" $GREEN
  else
    echo "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/99-${USER}"
  fi

  sudo visudo -cf "/etc/sudoers.d/99-${USER}"

  if [ $? -eq 0 ]; then
    say "Sudoers file is valid" $GREEN
  else
    say "Sudoers file is invalid" $RED
    return 1
  fi

  case $DISTRO in
    Arch|ArchLabs|cachyos|EndeavourOS)
      cat << EOF | sudo tee /etc/polkit-1/rules.d/49-nopasswd_global.rules
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("${USER}")) {
    return polkit.Result.YES;
  }
});
EOF
      sudo chmod 0644 /etc/polkit-1/rules.d/49-nopasswd_global.rules
      ;;
    Debian|Raspbian|MX|Pop)
      cat << EOF | sudo tee /etc/polkit-1/localauthority/50-local.d/admin_group.pkla
[set admin_group privs]
Identity=unix-group:sudo
Action=*
ResultActive=yes
EOF
      ;;
    *)
      say "Unsupported distribution for polkit setup." $RED
      return 1
  esac

  say "Sudoers and polkit setup completed." $GREEN
}

# --- Git Configuration (Idempotent) ---
setup_gitconfig() {

  # Check if git config already exists
  if git config --global --get user.name && git config --global --get user.email; then
    gum log --time rfc822 --level info "Git configuration already exists."
  else
    git_name=$(gum input --value "b08x" --prompt "Enter your Git username: ")
    git_email=$(gum input --value "rwpannick@gmail.com" --prompt "Enter your Git email: ")

    gum log --time rfc822 --level info "Setting up .gitconfig..."

    git config --global user.name "${git_name}"
    git config --global user.email "${git_email}"
  fi

  gum log --time rfc822 --level debug "Name: $(git config --global user.name)"
  gum log --time rfc822 --level debug "Email: $(git config --global user.email)"
}

# --- SSH Key Setup (Idempotent) ---
setup_ssh_keys() {
  if [ -f "${HOME}/.ssh/id_ed25519" ] && [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    say "SSH keys already exist." $GREEN
    return 0
  fi

  say "SSH keys not found. Attempting to transfer from another host." $YELLOW

  REMOTE_HOST=$(gum input --placeholder "hostname.domain.net" --prompt "Enter the hostname where SSH keys are stored: ")
  ssh_folder=$(gum input --value "${HOME}/.ssh" --prompt "Enter the folder name for SSH keys: ")

  # Copy SSH keys
  if rsync -avP --delete "${REMOTE_HOST}:~/.ssh/" "${HOME}/.ssh/"; then
    # Set proper permissions for SSH keys
    chmod 700 "${HOME}/.ssh"
    chmod 600 "${HOME}/.ssh"/*
    say "SSH keys successfully transferred and set up." $GREEN
    return 0
  else
    say "Failed to transfer SSH keys." $RED
    return 1
  fi
}
# --- Package Installation (Idempotent) ---
install_packages() {

  case $DISTRO in
    Arch|ArchLabs|cachyos|EndeavourOS)
      # Check if packages are already installed
      if ! pacman -Qi openssh base-devel rsync openssh python-pip \
      firewalld python-setuptools fd rubygems net-tools htop \
      gum most ranger nodejs npm ansible efibootmgr inxi fzf &> /dev/null; then
        say "Installing essential packages..." $GREEN
        sudo pacman -Syu --noconfirm --downloadonly --quiet
        sudo pacman -S --noconfirm openssh base-devel rsync openssh python-pip \
        firewalld python-setuptools fd rubygems \
        net-tools htop gum most ranger \
        nodejs npm ansible inxi efibootmgr fzf --overwrite '*'
      fi
      ;;
    Fedora|Fedora)
      # Check if packages are already installed
      if ! dnf list installed gum ansible inxi efibootmgr fzf &> /dev/null; then
        say "Installing essential packages..." $GREEN
        echo '[charm]
        name=Charm
        baseurl=https://repo.charm.sh/yum/
        enabled=1
        gpgcheck=1
        gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
        sudo dnf -y install gum ansible inxi efibootmgr fzf
      fi
      ;;
    Debian|Raspbian|MX|Pop)
      # Check if packages are already installed
      if ! dpkg -l openssh-server build-essential fd-find ruby-rubygems ruby-bundler ruby-dev gum ansible inxi efibootmgr fzf &> /dev/null; then
        say "Installing essential packages..." $GREEN
        if [ -f "/etc/apt/keyrings/charm.gpg" ]; then
          say "Charm keyring in place" $BLUE
        else
          sudo mkdir -p /etc/apt/keyrings
          curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
          echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        fi
        sudo apt-get update --quiet && \
        sudo apt-get install -y openssh-server build-essential fd-find ruby-rubygems ruby-bundler ruby-dev gum ansible inxi efibootmgr fzf
      fi
      ;;
    *)
      say "Unsupported distribution." $RED
      exit 1
  esac
}

# --- Repository Cloning (Idempotent) ---
clone_repository() {
  # Check if repository is already cloned
  if [ -d "${DOTFILES_DIR}" ]; then
    say "Repository already cloned.\n" $GREEN
    cd $ANSIBLE_HOME && git fetch && git pull
  else
    say "Select branch" $BLUE
    branch=$(gum choose --selected="development" "main" "development")
    say "Cloning SyncopatedOS repository..." $BLUE
    git clone --recursive -b "${branch}" git@github.com:b08x/SyncopatedOS "${DOTFILES_DIR}"
  fi
}

wipe() {
tput -S <<!
clear
cup 1
!
}

wipe
# --- Main Script ---
# Set up variables
USER_HOME="${HOME}"
CONFIG_DIR="${USER_HOME}/.config"
DOTFILES_DIR="${CONFIG_DIR}/dotfiles"
ANSIBLE_HOME="${DOTFILES_DIR}"

install_packages

gum style --border normal --margin "1" --padding "1 2" --border-foreground 212 "This bootstrap script is about to configure some shit. Welcome to $(gum style --foreground 212 'synflow')."

sleep 1

setup_ssh_keys
setup_gitconfig

sleep 1

# --- Sudoers Setup (Optional) ---
if gum confirm "Do you want to set up sudoers for passwordless sudo?" --default="Yes"; then
  setup_sudoers
  if [ $? -ne 0 ]; then
    say "Sudoers setup failed. Continuing with the rest of the script." $RED
  fi
else
  say "Skipping sudoers setup.\n" $BLUE
fi

clone_repository
sleep 1

# --- set the inventory file for intial boostrapin'
cat << EOF | tee "${ANSIBLE_HOME}/hosts"
[workstation]
localhost ansible_connection=local
EOF

# --- Environment Variables ---
say "Enter additional environment variables (press Enter with empty input to finish): \n" $BLUE

declare -A env_vars
declare var_name=""

while true; do
  var_name=$(gum input --width=0 --prompt "Variable name (or Enter to finish): ")

  if [[ -z "${var_name}" ]]; then
    break
  else
    var_value=$(gum input --prompt "Value for ${var_name}: ")
    env_vars["${var_name}"]="${var_value}"
  fi
done

# --- Ansible Playbook Execution ---
# wipe
say "Settting env vars and setup inventory for Playbook Execution...\n" $BLUE

env_command="env ANSIBLE_HOME=${ANSIBLE_HOME}"

for var in "${!env_vars[@]}"; do
  env_command+=" $var=${env_vars[$var]}"
done

say "And so it begins...\n" $BLUE

# gum spin --spinner dot --spinner.margin="2 2" --title "Running Setup Playbook..." -- '
eval "${env_command} ansible-playbook -i ${ANSIBLE_HOME}/hosts ${ANSIBLE_HOME}/playbooks/setup.yml"

sleep 5

# wipe

gum style --border normal --margin "1" --padding "1 2" --border-foreground 212 "This shit has been $(gum style --foreground 212 'configured')."

sleep 1

if gum confirm "Wanna reboot?" --default="Yes"; then
  say "rebooting..." $GREEN
  shutdown -r now
else
  say "not rebooting...." $YELLOW
  sleep 2
fi
