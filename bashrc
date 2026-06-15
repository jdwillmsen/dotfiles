# Dotfiles location (assumed: ~/dotfiles)
export DOTFILES="$HOME/dotfiles"

# Not running interactively? Stop here.
case $- in
    *i*) ;;
    *) return ;;
esac

# Shared config
source "$DOTFILES/shell/exports.sh"
source "$DOTFILES/shell/aliases.sh"
source "$DOTFILES/shell/functions.sh"

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:ignorespace
shopt -s histappend
shopt -s checkwinsize

# Prompt (simple; swap for starship later with: eval "$(starship init bash)")
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# nvm — Node version manager
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]             && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ]    && \. "$NVM_DIR/bash_completion"

# pyenv — Python version manager
if command -v pyenv &>/dev/null; then
    eval "$(pyenv init -)"
fi

# sdkman — Java/Kotlin version manager (must stay at bottom)
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
. "$HOME/.cargo/env"
