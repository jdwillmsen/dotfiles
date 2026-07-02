# shellcheck shell=bash
# Sourced by bashrc and zshrc; declares no shebang of its own.

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'

# Safety nets
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Git
alias g='git'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias gco='git checkout'
alias gsw='git switch'
alias gswc='git switch -c'
alias glog='git log --oneline --graph --decorate --all'
alias gdiff='git diff'
alias gstash='git stash'
alias gpop='git stash pop'

# Docker
alias d='docker'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias dimg='docker images'
alias drm='docker rm'
alias drmi='docker rmi'
alias dexec='docker exec -it'
alias dlogs='docker logs -f'
alias dc='docker compose'
alias dcu='docker compose up -d'
alias dcd='docker compose down'

# Kubernetes
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'
alias kgn='kubectl get nodes'
alias kdp='kubectl describe pod'
alias kds='kubectl describe service'
alias kdd='kubectl describe deployment'
alias klogs='kubectl logs -f'
alias kexec='kubectl exec -it'
alias kns='kubectl config set-context --current --namespace'
alias kctx='kubectl config use-context'
alias kctxs='kubectl config get-contexts'

# System
alias ports='ss -tulanp'
alias myip='curl -s ifconfig.me && echo'
alias diskusage='du -sh * | sort -h'
alias meminfo='free -h'
alias cpuinfo='lscpu'

# Misc
alias reload='source ~/.zshrc 2>/dev/null || source ~/.bashrc'
alias dotfiles='cd $DOTFILES'
alias jlabs='cd ~/projects/jdwlabs'
alias path='echo $PATH | tr : "\n"'
alias clauded='claude --dangerously-skip-permissions'
