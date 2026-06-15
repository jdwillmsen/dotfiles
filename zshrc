# Dotfiles location (assumed: ~/dotfiles)
export DOTFILES="$HOME/dotfiles"

# Shared config
source "$DOTFILES/shell/exports.sh"
source "$DOTFILES/shell/aliases.sh"
source "$DOTFILES/shell/functions.sh"

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt APPEND_HISTORY

# Completion
autoload -U compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'  # case-insensitive

# Directory navigation
setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS

# Prompt (simple; swap for starship later with: eval "$(starship init zsh)")
autoload -U colors && colors
PS1="%{$fg[green]%}%n@%m%{$reset_color%}:%{$fg[blue]%}%~%{$reset_color%}%# "

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

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<
alias clauded='claude --dangerously-skip-permissions'
